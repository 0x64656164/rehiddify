import 'dart:convert';
import 'dart:io';

import 'package:dartx/dartx.dart';
import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/db/db.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/features/profile/data/profile_data_mapper.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_failure.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/singbox/model/singbox_proxy_type.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:meta/meta.dart';

/// parse profile subscription url and headers for data
///
/// ***name parser hierarchy:***
/// - UserOverride.name
/// - `profile-title` header
/// - `content-disposition` header
/// - url fragment (example: `https://example.com/config#user`) -> name=`user`
/// - url filename extension (example: `https://example.com/config.json`) -> name=`config`
/// - if none of these methods return a non-blank string, switch(profileType)
/// - remote:  fallback to `Remote Profile`
/// - local: fallback to protocol, extracted from content by protocol()

class ProfileParser {
  static const infiniteTrafficThreshold = 920_233_720_368;
  static const infiniteTimeThreshold = 92_233_720_368;

  // ---------------------------------------------------------------------------
  // Allowed keys in profileOverride (merged into SingboxConfigOption at
  // connect-time via ConfigOptionRepository.fullOptionsOverrided).
  //
  // 'rules' is extracted automatically from the sing-box JSON config when the
  // subscription defines route.rule_set entries.  If no rule_set is present
  // the key is simply absent and the core uses the default empty-rules list.
  // ---------------------------------------------------------------------------
  static const allowedOverrideConfigs = [
    'connection-test-url',
    'direct-dns-address',
    'remote-dns-address',
    'warp',
    'warp2',
    'tls-tricks',
    'rules', // populated from route.rule_set in the sing-box profile JSON
  ];

  static const allowedProfileHeaders = [
    'profile-title',
    'content-disposition',
    'subscription-userinfo',
    'profile-update-interval',
    'support-url',
    'profile-web-page-url',
    'enable-warp',
    'enable-fragment',
  ];

  final Ref _ref;
  final DioHttpClient _httpClient;

  ProfileParser({required Ref ref, required DioHttpClient httpClient})
      : _ref = ref,
        _httpClient = httpClient;

  // ── public API ─────────────────────────────────────────────────────────────

  TaskEither<ProfileFailure, ProfileEntriesCompanion> addLocal({
    required String id,
    required String content,
    required String tempFilePath,
    required UserOverride? userOverride,
  }) {
    return TaskEither.tryCatch(
            () async {
          await expandRemoteLinesInParallel(
            tempFilePath: tempFilePath,
            httpClient: _httpClient,
            cancelToken: CancelToken(),
            ref: _ref,
          );
        }, (_, __) => ProfileFailure.unexpected())
        .flatMap((_) => TaskEither.fromEither(populateHeaders(content: content)))
        .flatMap(
          (populatedHeaders) => TaskEither.fromEither(
            parse(
              tempFilePath: tempFilePath,
              profile: ProfileEntity.local(
                id: id,
                active: true,
                name: '',
                lastUpdate: DateTime.now(),
                userOverride: userOverride,
                populatedHeaders: populatedHeaders,
              ),
            ).flatMap((profEntity) =>
                Either.tryCatch(() => profEntity.toInsertEntry(), ProfileFailure.unexpected)),
          ),
        );
  }

  TaskEither<ProfileFailure, ProfileEntriesCompanion> addRemote({
    required String id,
    required String url,
    required String tempFilePath,
    required UserOverride? userOverride,
    CancelToken? cancelToken,
  }) =>
      _downloadProfile(url, tempFilePath, cancelToken).flatMap(
        (remoteHeaders) => TaskEither.fromEither(
          populateHeaders(
            content: File(tempFilePath).readAsStringSync(),
            remoteHeaders: remoteHeaders,
          ),
        ).flatMap(
          (populatedHeaders) => TaskEither.fromEither(
            parse(
              tempFilePath: tempFilePath,
              profile: ProfileEntity.remote(
                id: id,
                active: true,
                name: '',
                url: url,
                lastUpdate: DateTime.now(),
                userOverride: userOverride,
                populatedHeaders: populatedHeaders,
              ),
            ).flatMap((profEntity) =>
                Either.tryCatch(() => profEntity.toInsertEntry(), ProfileFailure.unexpected)),
          ),
        ),
      );

  TaskEither<ProfileFailure, ProfileEntriesCompanion> updateRemote({
    required RemoteProfileEntity rp,
    required String tempFilePath,
    CancelToken? cancelToken,
  }) =>
      _downloadProfile(rp.url, tempFilePath, cancelToken).flatMap(
        (remoteHeaders) => TaskEither.fromEither(
          populateHeaders(
            content: File(tempFilePath).readAsStringSync(),
            remoteHeaders: remoteHeaders,
          ),
        ).flatMap(
          (populatedHeaders) => TaskEither.fromEither(
            parse(
              tempFilePath: tempFilePath,
              profile: rp.copyWith(populatedHeaders: populatedHeaders),
            ).flatMap((profEntity) =>
                Either.tryCatch(() => profEntity.toUpdateEntry(), ProfileFailure.unexpected)),
          ),
        ),
      );

  Either<ProfileFailure, ProfileEntriesCompanion> offlineUpdate({
    required ProfileEntity profile,
    required String tempFilePath,
  }) =>
      profile
          .map(
            remote: (rp) => parse(profile: rp, tempFilePath: tempFilePath),
            local: (lp) => parse(tempFilePath: tempFilePath, profile: lp),
          )
          .flatMap((profEntity) =>
              Either.tryCatch(() => profEntity.toUpdateEntry(), ProfileFailure.unexpected));

  // ── private download helper ─────────────────────────────────────────────────

  TaskEither<ProfileFailure, Map<String, dynamic>> _downloadProfile(
    String url,
    String tempFilePath,
    CancelToken? cancelToken,
  ) =>
      TaskEither.tryCatch(() async {
        final rs = await _httpClient
            .download(
          url.trim(),
          tempFilePath,
          cancelToken: cancelToken,
          userAgent: _ref.read(ConfigOptions.useXrayCoreWhenPossible)
              ? _httpClient.userAgent.replaceAll("HiddifyNext", "HiddifyNextX")
              : null,
        )
            .catchError((err) {
          if (CancelToken.isCancel(err as DioException)) {
            throw const ProfileFailure.cancelByUser(
                'HTTP request for getting profile content canceled by user.');
          }
          throw err;
        });
        await expandRemoteLinesInParallel(
          tempFilePath: tempFilePath,
          httpClient: _httpClient,
          cancelToken: cancelToken ?? CancelToken(),
          ref: _ref,
        );
        return rs.headers.map.map((key, value) {
          if (value.length == 1) return MapEntry(key, value.first);
          return MapEntry(key, value);
        });
      }, (err, st) => err is ProfileFailure ? err : ProfileFailure.unexpected(err, st));

  Future<void> expandRemoteLinesInParallel({
    required String tempFilePath,
    required DioHttpClient httpClient,
    required CancelToken cancelToken,
    required Ref ref,
    int parallelism = 4,
  }) async {
    final content = await File(tempFilePath).readAsString();
    final lines = content.split('\n');
    final results = List<String?>.filled(lines.length, null);
    int index = 0;

    Future<void> worker() async {
      while (true) {
        if (cancelToken.isCancelled) return;
        final currentIndex = index++;
        if (currentIndex >= lines.length) return;
        final line = lines[currentIndex];
        if (!line.startsWith('http://') && !line.startsWith('https://')) {
          results[currentIndex] = line.trim();
          continue;
        }
        try {
          final tmpPath = '$tempFilePath.$currentIndex';
          await httpClient.download(
            line,
            tmpPath,
            cancelToken: cancelToken,
            userAgent: ref.read(ConfigOptions.useXrayCoreWhenPossible)
                ? httpClient.userAgent
                    .replaceAll('HiddifyNext', 'HiddifyNextX')
                : null,
          );
          results[currentIndex] =
              (await File(tmpPath).readAsString()).trim();
        } catch (err) {
          if (err is DioException && CancelToken.isCancel(err)) return;
          results[currentIndex] = '';
        }
      }
    }

    await Future.wait(List.generate(parallelism, (_) => worker()));

    if (results.any((e) => e != null)) {
      final newContent = results.join("\n");
      await File(tempFilePath).writeAsString(newContent);
    }
  }

  // ── header helpers (static) ────────────────────────────────────────────────

  static Either<ProfileFailure, Map<String, dynamic>> populateHeaders({
    required String content,
    Map<String, dynamic>? remoteHeaders,
  }) =>
      Either.tryCatch(() {
        final contentHeaders = _parseHeadersFromContent(content);
        return _mergeAndValidateHeaders(contentHeaders, remoteHeaders ?? {});
      }, ProfileFailure.unexpected);

  static Map<String, dynamic> _mergeAndValidateHeaders(
    Map<String, dynamic> contentHeaders,
    Map<String, dynamic> remoteHeaders,
  ) {
    for (final entry in contentHeaders.entries) {
      if (!remoteHeaders.keys.contains(entry.key)) {
        remoteHeaders[entry.key] = entry.value;
      }
    }
    final headers = <String, dynamic>{};
    for (final entry in remoteHeaders.entries) {
      if (allowedProfileHeaders.contains(entry.key) &&
          entry.value != null &&
          entry.value.toString().isNotEmpty) {
        headers[entry.key] = entry.value;
      }
    }
    return headers;
  }

  static Map<String, dynamic> _parseHeadersFromContent(String content) {
    final headers = <String, dynamic>{};
    final content_ = safeDecodeBase64(content);
    final lines = content_.split("\n");
    final linesToProcess = lines.length < 10 ? lines.length : 10;
    for (int i = 0; i < linesToProcess; i++) {
      final line = lines[i];
      if (line.startsWith("#") || line.startsWith("//")) {
        final index = line.indexOf(':');
        if (index == -1) continue;
        final key = line
            .substring(0, index)
            .replaceFirst(RegExp("^#|//"), "")
            .trim()
            .toLowerCase();
        final value = line.substring(index + 1).trim();
        headers[key] = value;
      }
    }
    return headers;
  }

  static SubscriptionInfo? _parseSubscriptionInfo(String subInfoStr) {
    final values = subInfoStr.split(';');
    final map = {
      for (final v in values)
        v.split('=').first.trim():
            num.tryParse(v.split('=').second.trim())?.toInt()
    };
    if (map
        case {
          "upload": final upload?,
          "download": final download?,
          "total": final total,
          "expire": var expire
        }) {
      final total1 =
          (total == null || total == 0) ? infiniteTrafficThreshold + 1 : total;
      expire =
          (expire == null || expire == 0) ? infiniteTimeThreshold : expire;
      return SubscriptionInfo(
        upload: upload,
        download: download,
        total: total1,
        expire: DateTime.fromMillisecondsSinceEpoch(expire * 1000),
      );
    }
    return null;
  }

  // ── rule extraction (static, new) ──────────────────────────────────────────

  /// Tries to parse [tempFilePath] as a sing-box JSON config and extract
  /// `route.rule_set` entries.
  ///
  /// Each entry is converted to a map that matches the kebab-cased JSON
  /// representation of [SingboxRule]:
  /// ```json
  /// {"rule-set-url": "https://...", "outbound": "bypass"}
  /// ```
  ///
  /// The outbound action is resolved by looking up the rule_set tag inside
  /// `route.rules`.  If a tag has no corresponding rule, the outbound
  /// defaults to `"proxy"`.
  ///
  /// Returns **null** (= fall back to default empty rules) when:
  ///   - the file is not a valid JSON object,
  ///   - there is no `route` key,
  ///   - `route.rule_set` is absent or empty, or
  ///   - none of the rule_set entries contain a `url` field.
  static List<Map<String, dynamic>>? _extractRulesFromConfig(
      String tempFilePath) {
    try {
      final content = File(tempFilePath).readAsStringSync();
      final dynamic decoded = jsonDecode(content);
      if (decoded is! Map<String, dynamic>) return null;

      final route = decoded['route'];
      if (route is! Map<String, dynamic>) return null;

      final rawRuleSets = route['rule_set'];
      if (rawRuleSets is! List || rawRuleSets.isEmpty) return null;

      // ── step 1: build tag → outbound mapping from route.rules ─────────────
      final tagToOutbound = <String, String>{};
      final rawRules = route['rules'];
      if (rawRules is List) {
        for (final rule in rawRules) {
          if (rule is! Map<String, dynamic>) continue;
          final outbound = rule['outbound'];
          if (outbound is! String) continue;
          final ruleSet = rule['rule_set'];
          if (ruleSet is String) {
            tagToOutbound[ruleSet] = outbound;
          } else if (ruleSet is List) {
            for (final tag in ruleSet) {
              if (tag is String) tagToOutbound[tag] = outbound;
            }
          }
        }
      }

      // ── step 2: convert rule_set entries to SingboxRule-compatible JSON ────
      //
      // Only entries with a `url` field can be represented as SingboxRule
      // (which maps to the hiddify-core "rule-set-url" field).
      //
      // Entries WITHOUT a url (binary/local rule sets like "geosite-category-ads-all")
      // are intentionally skipped — they have no representation in SingboxRule and
      // must be part of the core config directly.  The caller (hiddify-core) already
      // receives the full sing-box JSON via validateConfigByPath / generateFullConfig,
      // so local rule_sets in the profile are handled there.
      final result = <Map<String, dynamic>>[];
      for (final rawRuleSet in rawRuleSets) {
        if (rawRuleSet is! Map<String, dynamic>) continue;
        final url = rawRuleSet['url'];
        if (url is! String || url.isEmpty) continue;
        final tag = rawRuleSet['tag'];
        final rawOutbound = (tag is String) ? tagToOutbound[tag] : null;
        result.add({
          'rule-set-url': url,
          'outbound': _mapSingboxOutbound(rawOutbound),
        });
      }

      return result.isEmpty ? null : result;
    } catch (_) {
      // Not a sing-box JSON config — fall back silently.
      return null;
    }
  }

  /// Maps a raw sing-box outbound action string to the [RuleOutbound] enum
  /// name used in [SingboxRule] JSON serialisation.
  ///
  /// Handles Hiddify §hide§ / §...§ suffixes that mark an outbound as hidden
  /// in the UI.  Example: "direct §hide§" → "bypass", not "proxy".
  static String _mapSingboxOutbound(String? outbound) {
    if (outbound == null) return 'proxy';
    // Strip §...§ annotations before comparing (Hiddify hides outbounds with them).
    final cleaned =
        outbound.replaceAll(RegExp(r'§[^§]*§'), '').trim().toLowerCase();
    switch (cleaned) {
      case 'direct':
      case 'bypass':
        return 'bypass';
      case 'block':
        return 'block';
      default:
        // Any named proxy outbound ("select", "url-test", etc.) → proxy.
        return 'proxy';
    }
  }

  // ── core parse logic (static) ───────────────────────────────────────────────

  @visibleForTesting
  static Either<ProfileFailure, ProfileEntity> parse(
          {required String tempFilePath, required ProfileEntity profile}) =>
      Either.tryCatch(() {
        final headers =
            Map<String, dynamic>.from(profile.populatedHeaders ?? {});
        var name = '';

        // ── name resolution ──────────────────────────────────────────────────
        if (profile.userOverride?.name case final String oName
            when oName.isNotEmpty) {
          name = oName;
        }
        if (headers['profile-title'] case final String titleHeader
            when name.isEmpty) {
          if (titleHeader.startsWith("base64:")) {
            name = utf8
                .decode(base64.decode(titleHeader.replaceFirst("base64:", "")));
          } else {
            name = titleHeader.trim();
          }
        }
        if (headers['content-disposition']
            case final String contentDispositionHeader when name.isEmpty) {
          final regExp = RegExp('filename="([^"]*)"');
          final match = regExp.firstMatch(contentDispositionHeader);
          if (match != null && match.groupCount >= 1) {
            name = match.group(1) ?? '';
          }
        }
        if (profile case RemoteProfileEntity(:final url)) {
          if (Uri.parse(url).fragment case final fragment when name.isEmpty) {
            name = fragment;
          }
          if (url.split("/").lastOrNull case final part? when name.isEmpty) {
            final pattern = RegExp(r"\.(json|yaml|yml|txt)[\s\S]*");
            name = part.replaceFirst(pattern, "");
          }
        }
        if (name.isBlank) {
          switch (profile) {
            case RemoteProfileEntity():
              name = "Remote Profile";
            case LocalProfileEntity():
              name = protocol(File(tempFilePath).readAsStringSync());
          }
        }

        // ── warp ─────────────────────────────────────────────────────────────
        if (headers['enable-warp'].toString() == 'true' ||
            profile.userOverride?.enableWarp == true) {
          final value = {'enable': true, 'mode': 'warp_over_proxy'};
          headers['warp'] = value;
          headers['warp2'] = value;
        }

        // ── tls fragment ──────────────────────────────────────────────────────
        if (headers['enable-fragment'].toString() == 'true' ||
            profile.userOverride?.enableFragment == true) {
          headers['tls-tricks'] = {'enable-fragment': true};
        }

        // ── route rules from subscription ─────────────────────────────────────
        //
        // If the subscription is a full sing-box config JSON that includes
        // `route.rule_set` entries, extract them and store as 'rules' in the
        // profileOverride JSON.  This value is persisted to the database and
        // later merged into SingboxConfigOption by
        // ConfigOptionRepository.fullOptionsOverrided(), replacing the default
        // empty list.
        //
        // If no rule_set definitions are found (the profile is a proxy list,
        // YAML/Clash config, or a sing-box config without rule_set), we leave
        // 'rules' absent so the default empty list is used — the "as usual"
        // fallback.
        //
        // The check `!headers.containsKey('rules')` is defensive: a future
        // allowedProfileHeaders extension could let subscriptions set rules via
        // HTTP headers, in which case those take precedence over the JSON body.
        if (!headers.containsKey('rules')) {
          final profileRules = _extractRulesFromConfig(tempFilePath);
          if (profileRules != null) {
            headers['rules'] = profileRules;
          }
        }

        // ── update interval ───────────────────────────────────────────────────
        final isAutoUpdateDisable =
            profile.userOverride?.isAutoUpdateDisable ?? false;
        ProfileOptions? options;
        if (profile.userOverride?.updateInterval case final int updateInterval
            when updateInterval > 0 && !isAutoUpdateDisable) {
          options =
              ProfileOptions(updateInterval: Duration(hours: updateInterval));
        }
        if (headers['profile-update-interval']
            case final String updateIntervalStr
            when options == null && !isAutoUpdateDisable) {
          final updateInterval =
              Duration(hours: int.parse(updateIntervalStr));
          options = ProfileOptions(updateInterval: updateInterval);
        }

        // ── subscription info ─────────────────────────────────────────────────
        SubscriptionInfo? subInfo;
        if (headers['subscription-userinfo'] case final String subInfoStr) {
          subInfo = _parseSubscriptionInfo(subInfoStr);
        }
        if (subInfo != null) {
          if (headers['profile-web-page-url']
              case final String profileWebPageUrl
              when isUrl(profileWebPageUrl)) {
            subInfo = subInfo.copyWith(webPageUrl: profileWebPageUrl);
          }
          if (headers['support-url'] case final String profileSupportUrl
              when isUrl(profileSupportUrl)) {
            subInfo = subInfo.copyWith(supportUrl: profileSupportUrl);
          }
        }

        // ── build profileOverride JSON ─────────────────────────────────────────
        // Strip every key not in allowedOverrideConfigs (which now includes
        // 'rules').  The resulting JSON is stored in the DB and applied at
        // connect-time via fullOptionsOverrided().
        headers.removeWhere(
          (key, value) =>
              !allowedOverrideConfigs.contains(key) ||
              value == null ||
              value.toString().isEmpty,
        );

        final profileOverrideStr =
            jsonEncode({for (final key in headers.keys) key: headers[key]});

        return profile.map(
          remote: (rp) => rp.copyWith(
            name: name,
            lastUpdate: DateTime.now(),
            options: options,
            subInfo: subInfo,
            profileOverride: profileOverrideStr,
          ),
          local: (lp) => lp.copyWith(
            name: name,
            lastUpdate: DateTime.now(),
            profileOverride: profileOverrideStr,
          ),
        );
      }, ProfileFailure.unexpected);

  // ── protocol detection ─────────────────────────────────────────────────────

  static String protocol(String content) {
    if (content.contains("[Interface]")) {
      return ProxyType.wireguard.label;
    }
    final lines = content.split('\n');
    String? name;
    for (final line in lines) {
      final uri = Uri.tryParse(line);
      if (uri == null) continue;
      final fragment = uri.hasFragment
          ? Uri.decodeComponent(uri.fragment.split(" -> ")[0])
          : null;
      name ??= switch (uri.scheme) {
        'ss' => fragment ?? ProxyType.shadowsocks.label,
        'ssconf' => fragment ?? ProxyType.shadowsocks.label,
        'vmess' => ProxyType.vmess.label,
        'vless' => fragment ?? ProxyType.vless.label,
        'trojan' => fragment ?? ProxyType.trojan.label,
        'tuic' => fragment ?? ProxyType.tuic.label,
        'hy2' || 'hysteria2' => fragment ?? ProxyType.hysteria2.label,
        'hy' || 'hysteria' => fragment ?? ProxyType.hysteria.label,
        'ssh' => fragment ?? ProxyType.ssh.label,
        'wg' => fragment ?? ProxyType.wireguard.label,
        'awg' => fragment ?? ProxyType.awg.label,
        'shadowtls' => fragment ?? ProxyType.shadowtls.label,
        'mieru' => fragment ?? ProxyType.mieru.label,
        'warp' => fragment ?? ProxyType.warp.label,
        _ => null,
      };
    }
    return name ?? ProxyType.unknown.label;
  }

  // ── override merge helpers (static) ────────────────────────────────────────

  static Map<String, dynamic> applyProfileOverride(
      Map<String, dynamic> main, String? profileOverride) {
    if (profileOverride == null) return main;
    if (profileOverride.contains("{")) {
      final profileOverrideMap =
          jsonDecode(profileOverride) as Map<String, dynamic>;
      return _mergeJson(main, profileOverrideMap);
    } else {
      return main;
    }
  }

  static Map<String, dynamic> _mergeJson(
      Map<String, dynamic> main, Map<String, dynamic> override) {
    override.forEach((key, value) {
      if (main.containsKey(key)) {
        if (main[key] is Map<String, dynamic> &&
            value is Map<String, dynamic>) {
          main[key] = _mergeJson(main[key] as Map<String, dynamic>, value);
        } else {
          // For lists (including 'rules'), the profile value fully replaces
          // the default value — this is the intended priority mechanism.
          main[key] = value;
        }
      } else {
        main[key] = value;
      }
    });
    return main;
  }
}
