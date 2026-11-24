import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/workflow.dart';

Map<String, dynamic> _recordedWorkflowJson() {
  final profile = jsonDecode(
    File('assets/defaultProfiles/7g_basket.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  profile['native_shaping'] = {
    'version': 1,
    'pump_curve': const [],
    'flow_tau': 0.5,
    'flow_mode': 'both',
    'pressure_tau': 0.5,
    'pressure_mode': 'both',
    'ramp_factor': 1.0,
  };
  return {
    'id': 'shot',
    'name': 'Recorded',
    'description': '',
    'profile': profile,
  };
}

void main() {
  test('setWorkflow with a recorded workflow drops its retired block, so the '
      'current workflow parses as a request', () {
    final controller = WorkflowController();
    final recorded = Workflow.fromRecordedJson(_recordedWorkflowJson());
    expect(recorded.profile.retiredNativeShapingJson, isNotNull);

    controller.setWorkflow(recorded.copyWith());

    final current = controller.currentWorkflow;
    expect(current.profile.retiredNativeShapingJson, isNull);
    expect(current.toJson()['profile'], isNot(contains('native_shaping')));
    expect(() => Workflow.fromJson(current.toJson()), returnsNormally);
  });

  test('updateWorkflow with a recorded profile drops its retired block', () {
    final controller = WorkflowController();
    final recorded = Profile.fromRecordedJson(
      _recordedWorkflowJson()['profile'] as Map<String, dynamic>,
    );

    controller.updateWorkflow(profile: recorded);

    expect(controller.currentWorkflow.profile.retiredNativeShapingJson, isNull);
    expect(controller.currentWorkflow.profile.title, recorded.title);
  });
}
