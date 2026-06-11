import 'dart:convert';
import 'dart:io';

import 'package:PiliPro/common/widgets/pendant_avatar.dart';
import 'package:PiliPro/models/dynamics/result.dart';
import 'package:flutter_test/flutter_test.dart';

/// 回归测试: B 站 feed/all 接口字段类型变更 (2026-06 观测到)。
/// - module_author.following: bool -> int (0/1)
/// - live_rcmd.content (JSON 字符串) 内 live_play_info.live_id: str -> int64
/// - 番剧(PGC)动态 major.pgc.epid / season_id: int -> str
/// 异常会被请求层 catch 成字符串展示在 UI 上, 第一个错误会掩盖后面的,
/// 因此这些点必须同时修复。夹具为手工构造的合成数据, 不含真实用户信息。
void main() {
  test('DynamicsDataModel parses items with changed field types', () {
    // 先给惰性静态字段赋值, 避免测试环境里初始化 Hive
    DynamicsDataModel.banWordForDyn = RegExp('', caseSensitive: false);
    DynamicsDataModel.enableFilter = false;
    DynamicsDataModel.antiGoodsDyn = false;
    PendantAvatar.showDynDecorate = true;

    final raw = File(
      'test/fixtures/dynamic_feed_type_change_sample.json',
    ).readAsStringSync();
    final json = jsonDecode(raw) as Map<String, dynamic>;

    final data = DynamicsDataModel.fromJson(json);

    expect(data.hasMore, true);
    expect(data.items, isNotNull);
    expect(data.items!.length, 3);

    // following: 1 -> true, 0 -> false
    expect(data.items![0].modules.moduleAuthor!.following, true);
    expect(data.items![1].modules.moduleAuthor!.following, false);

    // live_id: int64 -> String
    final live = data.items![1].modules.moduleDynamic!.major!.liveRcmd!;
    expect(live.liveId, '707000000000000001');
    expect(live.roomId, 1234567);
    expect(live.liveStatus, 1);
    expect(live.title, '测试直播标题');

    // 番剧(PGC): epid / season_id 字符串 -> int
    final pgc = data.items![2].modules.moduleDynamic!.major!.pgc!;
    expect(pgc.epid, 3915346);
    expect(pgc.seasonId, 216918);
    expect(pgc.title, '合成测试番剧标题');
  });
}
