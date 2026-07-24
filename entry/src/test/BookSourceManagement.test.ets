import { describe, it, expect } from '@ohos/hypium';
import { createEmptyBookSource, parseBookSource } from '../main/ets/model/BookSource';
import { CheckConfig, normalizeCheckConfig } from '../main/ets/service/SourceChecker';
import {
  DISABLE_COOKIE_HEADER, SourceNetworkPolicy
} from '../main/ets/engine/source/SourceNetworkPolicy';

export default function bookSourceManagementTest() {
  describe('bookSourceManagement', () => {
    it('usesAndroidCompatibleSourceDefaults', 0, () => {
      const source = parseBookSource(JSON.parse(
        '{"bookSourceName":"测试源","bookSourceUrl":"https://example.com","concurrentRate":"2/1000"}'));
      expect(source.respondTime).assertEqual(180000);
      expect(source.concurrentRate).assertEqual('2/1000');
      expect(source.enabledCookieJar).assertTrue();
      expect(createEmptyBookSource().respondTime).assertEqual(180000);
    });

    it('normalizesCheckDependencies', 0, () => {
      const rawConfig: CheckConfig = {
        keyword: '  ',
        timeout: 200,
        checkSearch: false,
        checkDiscovery: false,
        checkInfo: false,
        checkCategory: false,
        checkContent: true
      };
      const config = normalizeCheckConfig(rawConfig);
      expect(config.keyword).assertEqual('我');
      expect(config.timeout).assertEqual(1000);
      expect(config.checkSearch).assertTrue();
      expect(config.checkCategory).assertTrue();
    });

    it('appliesTimeoutAndCookiePolicyWithoutMutatingHeaders', 0, () => {
      const source = createEmptyBookSource();
      source.respondTime = 12345;
      source.enabledCookieJar = false;
      const original: Record<string, string> = { 'Accept': 'text/html' };
      const headers = SourceNetworkPolicy.headers(source, original);
      expect(SourceNetworkPolicy.timeout(source)).assertEqual(12345);
      expect(headers[DISABLE_COOKIE_HEADER]).assertEqual('1');
      expect(original[DISABLE_COOKIE_HEADER] === undefined).assertTrue();
    });
  });
}
