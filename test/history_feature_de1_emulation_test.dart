import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/history_feature/history_feature.dart';
import 'package:reaprime/src/models/data/shot_record.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'helpers/shot_event_storage.dart';

ShotRecord _shot({required bool emulated, String? title}) {
  final base = eventShot();
  final workflow = base.workflow;
  return base.copyWith(
    workflow: workflow.copyWith(
      id: workflow.id,
      profile: title == null ? null : workflow.profile.copyWith(title: title),
      machine: WorkflowMachine(
        provenanceStatus: WorkflowMachineProvenanceStatus.captured,
        de1Emulation: emulated,
      ),
    ),
  );
}

Future<void> _pumpHistory(WidgetTester tester, ShotRecord record) async {
  tester.view.physicalSize = const Size(1400, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final storage = ShotEventStorage()..shots[record.id] = record;
  final controller = PersistenceController(storageService: storage);
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    ShadApp(
      home: HistoryFeature(
        persistenceController: controller,
        workflowController: WorkflowController(),
        selectedShot: jsonEncode(record.toJson()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('History shows the B-DE1 name for an emulated shot', (
    tester,
  ) async {
    final record = _shot(emulated: true);
    final title = record.workflow.profile.title;
    await _pumpHistory(tester, record);

    expect(find.text('B-DE1 · $title'), findsNWidgets(2));
    expect(find.text(title), findsNothing);
    expect(
      find.bySemanticsLabel(RegExp(RegExp.escape('B-DE1 · $title'))),
      findsWidgets,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('History shows the plain name for a native shot', (tester) async {
    final record = _shot(emulated: false);
    final title = record.workflow.profile.title;
    await _pumpHistory(tester, record);

    expect(find.text(title), findsNWidgets(2));
    expect(find.textContaining('B-DE1'), findsNothing);
    expect(find.bySemanticsLabel(RegExp('B-DE1')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('History does not double the prefix', (tester) async {
    final record = _shot(emulated: true, title: 'B-DE1 · Imported');
    await _pumpHistory(tester, record);

    expect(find.text('B-DE1 · Imported'), findsNWidgets(2));
    expect(find.textContaining('B-DE1 · B-DE1'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
