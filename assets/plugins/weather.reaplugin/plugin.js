/* weather.reaplugin
 *
 * Contract:
 * - This file must define a function named 'createPlugin'
 * - Factory function receives 'host' object as parameter
 * - Returns a plugin object with onLoad, onUnload, onEvent methods
 *
 * Local weather for the live screen. Emits on the "weather" channel, which the manifest
 * declares as a websocket endpoint, so a skin reads it at
 * /ws/v1/plugins/weather.reaplugin/weather.
 *
 * WHY THE PLUGIN DOES THE ARITHMETIC RATHER THAN THE SKIN. Open-Meteo's DAILY answer
 * carries one rain probability for the whole day, which is not the question anyone asks
 * standing at a machine. Its HOURLY answer carries a value per hour, so the parts of the
 * day are bucketed here — where the location's own timezone is already known, and where
 * one implementation serves every skin.
 */

function createPlugin(host) {
  "use strict";

  var GEOCODE = "https://geocoding-api.open-meteo.com/v1/search";
  var FORECAST = "https://api.open-meteo.com/v1/forecast";

  /* THE THREE PARTS OF A DAY. Ben's call, 30 August 2026: morning 06-12, afternoon
   * 12-18, and everything else is night. The night bucket WRAPS midnight, which is why
   * it is expressed as a start hour and a length rather than a pair of bounds. */
  var PERIODS = [
    { id: "am", label: "AM", from: 6, to: 12 },
    { id: "pm", label: "PM", from: 12, to: 18 },
    { id: "night", label: "NIGHT", from: 18, to: 30 }
  ];

  var MIN_REFRESH_MINUTES = 10;
  var DEFAULT_REFRESH_MINUTES = 30;

  /* THE HEARTBEAT, AND IT IS NOT OPTIONAL.
   *
   * `plugins_handler.dart _handlePluginSocketEndpoint` subscribes a new socket to the
   * LIVE emit stream and replays nothing. So a skin that connects between two fetches
   * receives nothing at all until the next one — with a 30 minute refresh, a blank
   * widget for up to half an hour after every reload. Re-emitting the cached reading on
   * a short beat closes that window to seconds.
   *
   * It also keeps `ageMinutes` honest. The age is computed at emit time, so without a
   * beat a client would read "0 minutes ago" for the whole refresh interval, and the
   * skin's two-hour staleness rule would never fire. */
  var HEARTBEAT_MS = 30000;
  var COMPASS = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"];

  var state = {
    location: "",
    refreshMinutes: DEFAULT_REFRESH_MINUTES,
    units: "metric",
    place: null,
    coords: null,
    last: null,
    fetchedAt: null,
    timer: null,
    beat: null,
    inFlight: false
  };

  function log(msg) {
    host.log("[weather] " + msg);
  }

  /* ------------------------------------------------------------------ *
   * Units
   * ------------------------------------------------------------------ */

  function isImperial() {
    return String(state.units).toLowerCase() === "imperial";
  }

  function temp(c) {
    if (typeof c !== "number" || !isFinite(c)) return null;
    return isImperial() ? round(c * 9 / 5 + 32, 1) : round(c, 1);
  }

  /* One value out of an Open-Meteo `daily` block, for the location's today.
     TYPE FIRST, because Number(null) is 0 and 0 degrees is a real answer. */
  function dayAt(daily, field) {
    if (!daily || !Array.isArray(daily[field])) return null;
    var v = daily[field][0];
    return typeof v === "number" && isFinite(v) ? v : null;
  }

  function rain(mm) {
    if (typeof mm !== "number" || !isFinite(mm)) return 0;
    return isImperial() ? round(mm / 25.4, 2) : round(mm, 1);
  }

  function wind(kph) {
    if (typeof kph !== "number" || !isFinite(kph)) return null;
    return isImperial() ? Math.round(kph * 0.621371) : Math.round(kph);
  }

  function round(n, places) {
    var f = Math.pow(10, places);
    return Math.round(n * f) / f;
  }

  /* DEW POINT FROM TEMPERATURE AND HUMIDITY — the Magnus formula.
   *
   * Open-Meteo serves dew point hourly but not in its `current` block, and asking for an
   * extra hourly series to read one number is a bigger request for no benefit. The
   * formula is exact enough for a widget: within about 0.1 C over the range a kitchen
   * ever sees. */
  function dewPointC(tC, rh) {
    if (typeof tC !== "number" || typeof rh !== "number" || rh <= 0) return null;
    var a = 17.62;
    var b = 243.12;
    var g = Math.log(rh / 100) + (a * tC) / (b + tC);
    return (b * g) / (a - g);
  }

  function compass(deg) {
    if (typeof deg !== "number" || !isFinite(deg)) return null;
    return COMPASS[Math.round(deg / 45) % 8];
  }

  /* ------------------------------------------------------------------ *
   * The parts of the day
   * ------------------------------------------------------------------ */

  /**
   * WHICH PERIOD AN HOUR BELONGS TO. Night owns 18:00-06:00, so an hour before 6 belongs
   * to the night that STARTED YESTERDAY — that is what `dayOffset` records, and it is
   * what stops a 2 am reading being bucketed into a night eighteen hours away.
   */
  function periodOfHour(hour) {
    if (hour >= 6 && hour < 12) return { period: PERIODS[0], dayOffset: 0 };
    if (hour >= 12 && hour < 18) return { period: PERIODS[1], dayOffset: 0 };
    if (hour >= 18) return { period: PERIODS[2], dayOffset: 0 };
    return { period: PERIODS[2], dayOffset: -1 };
  }

  /** The period that follows this one, and whether it starts on the next day. */
  function nextSlot(slot) {
    if (slot.period.id === "am") return { period: PERIODS[1], dayOffset: slot.dayOffset };
    if (slot.period.id === "pm") return { period: PERIODS[2], dayOffset: slot.dayOffset };
    return { period: PERIODS[0], dayOffset: slot.dayOffset + 1 };
  }

  function dayKey(base, offset) {
    var d = new Date(base.getTime());
    d.setDate(d.getDate() + offset);
    var m = d.getMonth() + 1;
    var day = d.getDate();
    return d.getFullYear() + "-" + (m < 10 ? "0" : "") + m + "-" + (day < 10 ? "0" : "") + day;
  }

  /**
   * THE PEAK ACROSS A BUCKET, NOT THE MEAN — and this is a deliberate choice.
   *
   * One 90 % hour inside an otherwise quiet afternoon is exactly the thing a person
   * wanted warning of, and an average buries it. Rainfall is summed instead, because
   * that is what "how much" means over a stretch of hours.
   */
  function bucket(hourly, base, slot) {
    var startDay = dayKey(base, slot.dayOffset);
    var from = slot.period.from;
    var to = slot.period.to;
    var peak = 0;
    var total = 0;
    var seen = 0;

    for (var i = 0; i < hourly.time.length; i++) {
      var stamp = hourly.time[i];
      var day = stamp.slice(0, 10);
      var hour = parseInt(stamp.slice(11, 13), 10);
      var offsetHours;

      if (day === startDay) {
        offsetHours = hour;
      } else if (day === dayKey(base, slot.dayOffset + 1)) {
        offsetHours = hour + 24;
      } else {
        continue;
      }
      if (offsetHours < from || offsetHours >= to) continue;

      seen++;
      var p = hourly.precipitation_probability ? hourly.precipitation_probability[i] : null;
      var mm = hourly.precipitation ? hourly.precipitation[i] : null;
      if (typeof p === "number" && p > peak) peak = p;
      if (typeof mm === "number") total += mm;
    }

    return {
      id: slot.period.id,
      label: slot.period.label,
      fromHour: from % 24,
      toHour: to % 24,
      tomorrow: slot.dayOffset > 0,
      probability: seen ? Math.round(peak) : null,
      amount: seen ? rain(total) : null
    };
  }

  /**
   * THE NEXT THREE PARTS OF THE DAY, FORWARD ONLY, the running one first.
   *
   * Ben's call, 30 August 2026: "a rolling window with current on the left and next on
   * the right." The corner draws the first two and the modal draws all three, so the two
   * surfaces can never disagree about what NIGHT covers.
   */
  function periodsFrom(hourly, now) {
    var slot = periodOfHour(now.getHours());
    var out = [];
    for (var i = 0; i < 3; i++) {
      out.push(bucket(hourly, now, slot));
      slot = nextSlot(slot);
    }
    return out;
  }

  /* ------------------------------------------------------------------ *
   * The network
   * ------------------------------------------------------------------ */

  async function resolvePlace(query) {
    var url = GEOCODE + "?name=" + encodeURIComponent(query) + "&count=1&language=en&format=json";
    var res = await fetch(url);
    if (!res.ok) throw new Error("geocoding answered " + res.status);
    var body = await res.json();
    if (!body.results || !body.results.length) return null;
    var r = body.results[0];
    return {
      latitude: r.latitude,
      longitude: r.longitude,
      name: [r.name, r.admin1, r.country].filter(Boolean).join(", ")
    };
  }

  async function readWeather(coords) {
    var url = FORECAST
      + "?latitude=" + encodeURIComponent(coords.latitude)
      + "&longitude=" + encodeURIComponent(coords.longitude)
      + "&current=temperature_2m,relative_humidity_2m,apparent_temperature,is_day,"
      + "weather_code,surface_pressure,wind_speed_10m,wind_direction_10m"
      + "&hourly=precipitation_probability,precipitation"
      /* TODAY'S HIGH AND LOW — Ben, 30 August 2026, on the space beside the corner's
         temperature. `daily` is asked in the LOCATION's timezone (timezone=auto below),
         so index 0 is that place's today and not the tablet's. */
      + "&daily=temperature_2m_max,temperature_2m_min"
      + "&timezone=auto&forecast_days=3";
    var res = await fetch(url);
    if (!res.ok) throw new Error("forecast answered " + res.status);
    return res.json();
  }

  /* ------------------------------------------------------------------ *
   * The reading
   * ------------------------------------------------------------------ */

  function refuse(reason) {
    var payload = { ok: false, reason: reason, units: isImperial() ? "imperial" : "metric" };
    if (state.place) payload.place = state.place;
    host.emit("weather", payload);
  }

  async function refresh() {
    if (state.inFlight) return;
    if (!state.location) {
      refuse("no_location");
      return;
    }
    state.inFlight = true;
    try {
      if (!state.coords) {
        var found = await resolvePlace(state.location);
        if (!found) {
          log("no place matched \"" + state.location + "\"");
          refuse("unknown_place");
          return;
        }
        state.coords = { latitude: found.latitude, longitude: found.longitude };
        state.place = found.name;
        log("resolved \"" + state.location + "\" to " + state.place);
      }

      var body = await readWeather(state.coords);
      var c = body.current || {};
      /* The response's own clock, not the machine's: the buckets are the LOCATION's
       * parts of the day, and a tablet set to another timezone must not shift them. */
      var now = new Date(c.time || body.current_weather_time || Date.now());
      var tC = c.temperature_2m;
      var rh = c.relative_humidity_2m;

      var reading = {
        ok: true,
        place: state.place,
        observedAt: c.time || null,
        ageMinutes: 0,
        isDay: c.is_day === 1 || c.is_day === true,
        code: typeof c.weather_code === "number" ? c.weather_code : null,
        temperature: temp(tC),
        apparent: temp(c.apparent_temperature),
        humidity: typeof rh === "number" ? Math.round(rh) : null,
        dewPoint: temp(dewPointC(tC, rh)),
        wind: wind(c.wind_speed_10m),
        windFrom: compass(c.wind_direction_10m),
        pressure: typeof c.surface_pressure === "number" ? Math.round(c.surface_pressure) : null,
        /* TODAY'S RANGE, OR NULLS. Read at index 0 because `timezone=auto` makes the
           daily arrays the LOCATION's days. Absent is null and never a zero: a zero high
           is a real temperature, and the corner draws a dash for null. */
        high: temp(dayAt(body.daily, "temperature_2m_max")),
        low: temp(dayAt(body.daily, "temperature_2m_min")),
        units: isImperial() ? "imperial" : "metric",
        periods: body.hourly ? periodsFrom(body.hourly, now) : []
      };

      state.last = reading;
      state.fetchedAt = Date.now();
      publish();
      host.storage({
        type: "write",
        key: "lastReading",
        namespace: "weather.reaplugin",
        data: { reading: reading, fetchedAt: state.fetchedAt, place: state.place, coords: state.coords }
      });
    } catch (err) {
      log("fetch failed: " + (err && err.message ? err.message : err));
      /* A FAILURE DOES NOT ERASE WHAT WE HAVE. The cached reading keeps being published
       * with its true age, and the skin decides when it is too old to show — two hours,
       * Ben's call. A widget that blanks on one lost request is worse than one that says
       * how old its number is. */
      if (state.last) publish();
      else refuse("offline");
    } finally {
      state.inFlight = false;
    }
  }

  function publish() {
    if (!state.last) return;
    var age = state.fetchedAt ? Math.round((Date.now() - state.fetchedAt) / 60000) : null;
    var out = {};
    for (var k in state.last) if (Object.prototype.hasOwnProperty.call(state.last, k)) out[k] = state.last[k];
    out.ageMinutes = age;
    host.emit("weather", out);
  }

  function line(reading) {
    if (!reading || !reading.ok) return "Weather unavailable";
    var unit = reading.units === "imperial" ? "°F" : "°C";
    var first = reading.periods && reading.periods[0];
    var tail = first && first.probability !== null
      ? ", " + first.label + " rain " + first.probability + "%"
      : "";
    return reading.place + " " + reading.temperature + unit + tail;
  }

  /* ------------------------------------------------------------------ *
   * The timer
   * ------------------------------------------------------------------ */

  function schedule() {
    stop();
    var minutes = Math.max(MIN_REFRESH_MINUTES, state.refreshMinutes || DEFAULT_REFRESH_MINUTES);
    /* SELF-RESCHEDULING rather than setInterval: a fetch that takes longer than the
     * interval must not stack a second one behind it, and `refresh` is async. */
    state.timer = setTimeout(function () {
      refresh().then(schedule, schedule);
    }, minutes * 60 * 1000);
    beat();
  }

  function stop() {
    if (state.timer) {
      clearTimeout(state.timer);
      state.timer = null;
    }
    if (state.beat) {
      clearTimeout(state.beat);
      state.beat = null;
    }
  }

  /**
   * Re-publish what we already have, so a socket that opens late is not left blank.
   *
   * A SELF-RESCHEDULING setTimeout, NOT setInterval: the runtime provides only
   * `setTimeout` and `clearTimeout` (doc/Plugins.md, "Available in JavaScript Runtime"),
   * so `setInterval` is undefined here and calling it throws.
   */
  function beat() {
    if (state.beat) return;
    state.beat = setTimeout(function () {
      state.beat = null;
      if (state.last) publish();
      else if (!state.location) refuse("no_location");
      beat();
    }, HEARTBEAT_MS);
  }

  function applySettings(settings) {
    if (!settings) return false;
    var before = state.location;
    if (settings.Location !== undefined) state.location = String(settings.Location || "").trim();
    if (settings.RefreshMinutes !== undefined) {
      var n = Number(settings.RefreshMinutes);
      state.refreshMinutes = isFinite(n) && n > 0 ? n : DEFAULT_REFRESH_MINUTES;
    }
    if (settings.Units !== undefined) {
      var u = String(settings.Units || "").toLowerCase();
      state.units = u === "imperial" ? "imperial" : "metric";
    }
    /* A NEW LOCATION DROPS THE COORDINATES, or the next reading would be the old place's
     * weather under the new place's name. */
    if (state.location !== before) {
      state.coords = null;
      state.place = null;
      state.last = null;
      return true;
    }
    return false;
  }

  return {
    id: "weather.reaplugin",
    version: "1.0.0",

    onLoad(settings) {
      applySettings(settings);
      log("loaded for \"" + (state.location || "(no location set)") + "\"");
      host.storage({ type: "read", key: "lastReading", namespace: "weather.reaplugin" });
      refresh().then(schedule, schedule);
    },

    onUnload() {
      stop();
      state.last = null;
      state.coords = null;
    },

    onEvent(event) {
      if (!event || typeof event.name !== "string") return;

      switch (event.name) {
        case "settingsUpdated":
          if (applySettings(event.payload)) log("location changed; re-resolving");
          refresh().then(schedule, schedule);
          break;

        case "storageRead":
          /* WARM START. The cached reading goes out at once with its real age, so a
           * tablet that has just woken shows a number instead of a gap while the first
           * fetch is in flight. The skin hides it if it is too old. */
          if (event.payload && event.payload.key === "lastReading" && event.payload.data) {
            var d = event.payload.data;
            if (d.reading && !state.last) {
              state.last = d.reading;
              state.fetchedAt = d.fetchedAt || null;
              state.place = d.place || state.place;
              state.coords = d.coords || state.coords;
              publish();
            }
          }
          break;

        case "shutdown":
          stop();
          break;

        default:
          break;
      }
    }
  };
}
