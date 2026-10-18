import 'package:flutter/material.dart';

import '../core/models/nav_route.dart';

extension TurnTypeIcon on TurnType {
  IconData get icon => switch (this) {
        TurnType.left => Icons.turn_left,
        TurnType.right => Icons.turn_right,
        TurnType.sharpLeft => Icons.turn_sharp_left,
        TurnType.sharpRight => Icons.turn_sharp_right,
        TurnType.slightLeft => Icons.turn_slight_left,
        TurnType.slightRight => Icons.turn_slight_right,
        TurnType.straight => Icons.straight,
        TurnType.enterRoundabout => Icons.roundabout_left,
        TurnType.exitRoundabout => Icons.roundabout_right,
        TurnType.uTurn => Icons.u_turn_left,
        TurnType.goal => Icons.flag,
        TurnType.depart => Icons.navigation,
        TurnType.keepLeft => Icons.fork_left,
        TurnType.keepRight => Icons.fork_right,
      };
}
