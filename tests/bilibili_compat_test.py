"""Offline regression tests using the real yt-dlp parser and plugin base class."""
import importlib.util
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from yt_dlp import YoutubeDL
from yt_dlp.extractor.bilibili import BiliBiliIE


plugin_file = Path(sys.argv.pop(1))
spec = importlib.util.spec_from_file_location('bilibili_compat_test_target', plugin_file)
plugin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plugin)


class BilibiliCompatibilityTests(unittest.TestCase):
    URL = 'https://www.bilibili.com/video/BV1iWJv6GEvX/?p=3'
    STATE = 'window.__INITIAL_STATE__={"videoData":{"bvid":"BV1iWJv6GEvX"}};'
    EMPTY = '<script>window.__INITIAL_STATE__={};</script>'

    def setUp(self):
        self.ydl = YoutubeDL({'quiet': True})
        self.addCleanup(self.ydl.close)
        self.ie = plugin._BilibiliCompatibilityIE(self.ydl)
        self.handle = SimpleNamespace(url=self.URL)

    def fetch(self, replies, url=None):
        with patch.object(BiliBiliIE, '_download_webpage_handle', side_effect=replies) as request:
            result = self.ie._download_webpage_handle(
                url or self.URL, '1iWJv6GEvX', headers={'Referer': 'https://www.bilibili.com/'})
        return result, request

    def test_normal_page_uses_one_request(self):
        original = (self.STATE, self.handle)
        result, request = self.fetch([original])
        self.assertIs(result, original)
        self.assertEqual(request.call_count, 1)

    def test_missing_state_retries_same_video_and_part_once(self):
        result, request = self.fetch([(self.EMPTY, self.handle), (self.STATE, object())])
        self.assertEqual(request.call_count, 2)
        self.assertEqual(request.call_args.args, (
            'https://www.bilibili.com/en/video/BV1iWJv6GEvX/?p=3', '1iWJv6GEvX'))
        self.assertEqual(request.call_args.kwargs, {
            'headers': {'Referer': 'https://www.bilibili.com/'}, 'fatal': False})
        self.assertEqual(result[0], self.STATE)
        self.assertIs(result[1], self.handle)

    def test_av_url_and_query_are_preserved(self):
        _, request = self.fetch([(self.EMPTY, self.handle), (self.STATE, object())],
                                'https://bilibili.com/video/av123?p=2')
        self.assertEqual(request.call_args.args[0], 'https://bilibili.com/en/video/av123?p=2')

    def test_non_video_and_already_localized_urls_are_untouched(self):
        for url in ('https://www.bilibili.com/en/video/BV1iWJv6GEvX/?p=3',
                    'https://www.bilibili.com/festival/test?bvid=BV1iWJv6GEvX',
                    'https://api.bilibili.com/x/player/playurl',
                    'https://bilibili.com.evil/video/BV1iWJv6GEvX/'):
            with self.subTest(url=url):
                original = (self.EMPTY, self.handle)
                result, request = self.fetch([original], url)
                self.assertIs(result, original)
                self.assertEqual(request.call_count, 1)

    def test_explicit_access_error_is_left_to_official_extractor(self):
        for code in (-403, -404):
            with self.subTest(code=code):
                original = ('window.__INITIAL_STATE__={"error":{"trueCode":%d}};' % code,
                            self.handle)
                result, request = self.fetch([original])
                self.assertIs(result, original)
                self.assertEqual(request.call_count, 1)

    def test_risk_challenge_does_not_trigger_retry(self):
        original = ('window._riskdata_={"v_voucher":"challenge"};', self.handle)
        result, request = self.fetch([original])
        self.assertIs(result, original)
        self.assertEqual(request.call_count, 1)

    def test_failed_initial_request_does_not_trigger_retry(self):
        result, request = self.fetch([False])
        self.assertIs(result, False)
        self.assertEqual(request.call_count, 1)

    def test_failed_or_empty_localized_page_keeps_original(self):
        for fallback in (False, ('<html>No state</html>', object()),
                         (self.EMPTY, object())):
            with self.subTest(fallback=fallback):
                original = (self.EMPTY, self.handle)
                result, request = self.fetch([original, fallback])
                self.assertIs(result, original)
                self.assertEqual(request.call_count, 2)


if __name__ == '__main__':
    unittest.main(verbosity=2)
