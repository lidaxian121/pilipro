import 'dart:convert';
import 'dart:io';

import 'package:PiliPro/models/dynamics/up.dart';
import 'package:flutter_test/flutter_test.dart';

/// 回归测试: B 站 web-dynamic/v1/portal 接口字段类型变更 (2026-06 观测到)。
/// - live_users.items[].mid: int -> str
/// - live_users.items[].room_id: int -> str
/// 解析炸掉后 followUp() 没有 catch, 动态页左侧 up 主列表整体空白;
/// 且只在有关注的 UP 开播 (live_users.items 非空) 时触发, 表现为间歇性。
/// 夹具为手工构造的合成数据, 不含真实用户信息。
void main() {
  test('FollowUpModel parses portal response with string mid/room_id', () {
    final raw = File(
      'test/fixtures/portal_up_list_type_change_sample.json',
    ).readAsStringSync();
    final json = jsonDecode(raw) as Map<String, dynamic>;

    final data = FollowUpModel.fromJson(json);

    // live_users: mid/room_id 字符串 -> int
    final liveItems = data.liveUsers!.items!;
    expect(liveItems.length, 2);
    expect(liveItems[0].mid, 10000001);
    expect(liveItems[0].roomId, 21000001);
    expect(liveItems[1].mid, 10000002);
    expect(liveItems[1].roomId, 21000002);
    expect(liveItems[1].isReserveRecall, true);

    // up_list: 当前 mid 仍是 int, 但需兼容未来转 str
    expect(data.upList.length, 2);
    expect(data.upList[0].mid, 20000001);
    expect(data.upList[1].mid, 20000002);
    expect(data.hasMore, true);
    expect(data.offset, '5_1718000000');
  });
}
