"""Minimal Chrome DevTools pipe client for fixed-viewport SVG screenshots.

Uses only the standard library. Chrome owns SVG interpretation; Pillow never
interprets SVG. No listening debug port or screenshot-window size heuristic.
"""
import base64
import io
import json
import os
import select
import subprocess
import time
from PIL import Image


class SvgBrowser:
    def __init__(self, executable, profile):
        to_read, self.to_browser = os.pipe()
        self.from_browser, from_write = os.pipe()
        self.process = subprocess.Popen(
            ['/bin/sh', '-c', f'exec "$@" --remote-debugging-pipe 3<&{to_read} 4>&{from_write}',
             'svg-browser', str(executable), '--headless=new', '--disable-gpu',
             '--disable-breakpad', '--disable-crash-reporter', '--no-first-run',
             '--no-sandbox', f'--user-data-dir={profile}'],
            pass_fds=(to_read, from_write), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        os.close(to_read); os.close(from_write)
        self.buffer = b''
        self.serial = 0

    def call(self, method, params=None, session=None):
        self.serial += 1
        request = {'id': self.serial, 'method': method, 'params': params or {}}
        if session: request['sessionId'] = session
        os.write(self.to_browser, json.dumps(request).encode() + b'\0')
        deadline = time.monotonic() + 30
        while True:
            if b'\0' not in self.buffer:
                if not select.select([self.from_browser], [], [], max(0, deadline-time.monotonic()))[0]:
                    raise RuntimeError(f'Chrome timed out: {method}')
                chunk = os.read(self.from_browser, 1 << 20)
                if not chunk: raise RuntimeError(f'Chrome closed its DevTools pipe: {method}')
                self.buffer += chunk
                continue
            message, self.buffer = self.buffer.split(b'\0', 1)
            result = json.loads(message)
            if result.get('id') != self.serial: continue
            if 'error' in result: raise RuntimeError(result['error'])
            return result.get('result', {})

    def render(self, url, size):
        target = self.call('Target.createTarget', {'url': 'about:blank'})['targetId']
        session = self.call('Target.attachToTarget', {'targetId': target, 'flatten': True})['sessionId']
        self.call('Emulation.setDeviceMetricsOverride', {'width': size, 'height': size,
                  'deviceScaleFactor': 1, 'mobile': False}, session)
        self.call('Emulation.setDefaultBackgroundColorOverride', {'color': {'r': 0, 'g': 0, 'b': 0, 'a': 0}}, session)
        self.call('Page.navigate', {'url': url}, session)
        self.call('Runtime.evaluate', {'expression': 'Promise.all([...document.images].map(i=>i.decode()))',
                  'awaitPromise': True}, session)
        metrics = self.call('Page.getLayoutMetrics', session=session)['cssLayoutViewport']
        if (metrics['clientWidth'], metrics['clientHeight']) != (size, size):
            raise RuntimeError('Chrome did not apply the explicit SVG viewport')
        result = self.call('Page.captureScreenshot', {'format': 'png', 'captureBeyondViewport': False}, session)
        self.call('Target.closeTarget', {'targetId': target})
        return Image.open(io.BytesIO(base64.b64decode(result['data']))).convert('RGBA')

    def close(self):
        try: self.call('Browser.close')
        except (RuntimeError, BrokenPipeError): pass
        try: self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.kill(); self.process.wait()
        os.close(self.to_browser); os.close(self.from_browser)
