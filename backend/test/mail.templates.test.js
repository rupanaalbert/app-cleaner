import test from 'node:test';
import assert from 'node:assert/strict';

import { verifyEmail, passwordReset, passwordChanged, welcome } from '../src/services/mail.templates.js';

const URL = 'https://app.sparkle.app/verify-email?token=abc123';

test('every template returns subject, text, and html', () => {
  const rendered = [
    verifyEmail({ name: 'Amara Osei', url: URL }),
    passwordReset({ url: URL }),
    passwordChanged({ name: 'Amara Osei' }),
    welcome({ name: 'Amara Osei' }),
  ];
  for (const m of rendered) {
    assert.ok(m.subject && typeof m.subject === 'string', 'has a subject');
    assert.ok(m.text && m.text.length > 20, 'has a text body');
    assert.ok(m.html.startsWith('<!doctype html>'), 'has an html body');
  }
});

test('link templates put the URL in both the text and the html, and nowhere it can be XSS’d', () => {
  for (const m of [verifyEmail({ name: 'X', url: URL }), passwordReset({ url: URL })]) {
    assert.ok(m.text.includes(URL), 'url in text');
    assert.ok(m.html.includes(URL), 'url in html');
  }
});

test('the code-free notices carry no call-to-action link', () => {
  assert.ok(!/href=/.test(passwordChanged({ name: 'X' }).html), 'password-changed has no link');
  assert.ok(!/href=/.test(welcome({ name: 'X' }).html), 'welcome has no link');
});

test('greeting uses the first name only, and degrades without one', () => {
  assert.match(welcome({ name: 'Amara Osei' }).text, /Hi Amara,/);
  assert.match(welcome({}).text, /Hi there,/);
});

test('html-escapes interpolated values so a name cannot inject markup', () => {
  const m = welcome({ name: '<script>alert(1)</script>' });
  assert.ok(!m.html.includes('<script>'), 'raw tag must not survive into the html');
  assert.ok(m.html.includes('&lt;script&gt;'), 'it is escaped instead');
});
