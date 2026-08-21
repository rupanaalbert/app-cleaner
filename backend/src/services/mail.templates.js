// Transactional email copy. Pure functions: data in, { subject, text, html }
// out — no config, no I/O — so they render identically in a test as in prod and
// can be checked without a database or a provider key. MailService owns
// delivery and turns tokens into links; this file owns words and markup.

const esc = (value) => String(value ?? '').replace(/[&<>"]/g, (c) => (
  { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]
));

const greeting = (name) => (name ? `Hi ${name.split(' ')[0]},` : 'Hi there,');

// One spare, inline-styled shell — email clients don't do <style> or classes
// reliably. `button` is optional so the password-changed / welcome notes render
// without a call to action.
function shell({ heading, lines, button }) {
  const paragraphs = lines.map((l) => `<p style="margin:0 0 16px;color:#33484F;line-height:1.6">${esc(l)}</p>`).join('');
  const cta = button
    ? `<p style="margin:24px 0"><a href="${esc(button.url)}" style="display:inline-block;background:#12A088;color:#fff;text-decoration:none;padding:12px 22px;border-radius:8px;font-weight:600">${esc(button.label)}</a></p>`
    : '';
  const fallback = button
    ? `<p style="margin:0 0 16px;color:#6B8087;font-size:13px;line-height:1.6">If the button doesn't work, paste this link into your browser:<br>${esc(button.url)}</p>`
    : '';
  return `<!doctype html><html><body style="margin:0;background:#FAFBFA;padding:24px;font-family:ui-sans-serif,system-ui,-apple-system,sans-serif">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center">
    <table role="presentation" width="480" cellpadding="0" cellspacing="0" style="background:#fff;border:1px solid #DCE7E4;border-radius:14px;overflow:hidden">
      <tr><td style="background:#0E3A45;padding:18px 28px;color:#fff;font-weight:600">Sparkle</td></tr>
      <tr><td style="padding:28px">
        <h1 style="margin:0 0 16px;font-size:20px;color:#0B1F26">${esc(heading)}</h1>
        ${paragraphs}${cta}${fallback}
      </td></tr>
      <tr><td style="padding:16px 28px;background:#F5F8F7;color:#6B8087;font-size:12px">Sparkle — on-demand home cleaning.</td></tr>
    </table>
  </td></tr></table>
</body></html>`;
}

export function verifyEmail({ name, url }) {
  const heading = 'Confirm your email';
  const lines = [
    greeting(name).replace(/,$/, ''),
    'Confirm your email address to finish setting up your Sparkle account.',
    'This link expires in 24 hours. If you didn’t create an account, you can ignore this email.',
  ];
  return {
    subject: 'Confirm your email for Sparkle',
    text: `${greeting(name)}\n\nConfirm your email to finish setting up your Sparkle account:\n${url}\n\nThis link expires in 24 hours. If you didn’t create an account, ignore this email.`,
    html: shell({ heading, lines, button: { label: 'Confirm email', url } }),
  };
}

export function passwordReset({ url }) {
  const heading = 'Reset your password';
  const lines = [
    'We received a request to reset your Sparkle password.',
    'This link expires in 1 hour and can be used once. If you didn’t ask for this, ignore this email — your password won’t change.',
  ];
  return {
    subject: 'Reset your Sparkle password',
    text: `We received a request to reset your Sparkle password:\n${url}\n\nThis link expires in 1 hour and can be used once. If you didn’t ask for this, ignore this email — your password won’t change.`,
    html: shell({ heading, lines, button: { label: 'Reset password', url } }),
  };
}

export function passwordChanged({ name }) {
  const heading = 'Your password was changed';
  const lines = [
    greeting(name).replace(/,$/, ''),
    'Your Sparkle password was just changed and every signed-in session was ended.',
    'If this was you, no action is needed. If it wasn’t, reset your password immediately and contact support.',
  ];
  return {
    subject: 'Your Sparkle password was changed',
    text: `${greeting(name)}\n\nYour Sparkle password was just changed and every signed-in session was ended.\n\nIf this was you, no action is needed. If it wasn’t, reset your password immediately and contact support.`,
    html: shell({ heading, lines }),
  };
}

export function welcome({ name }) {
  const heading = 'Welcome to Sparkle';
  const lines = [
    greeting(name).replace(/,$/, ''),
    'Your email is confirmed and your account is ready. Book a clean in a couple of taps, track your cleaner on the way, and pay only when the job is done.',
  ];
  return {
    subject: 'Welcome to Sparkle',
    text: `${greeting(name)}\n\nYour email is confirmed and your account is ready. Book a clean in a couple of taps, track your cleaner on the way, and pay only when the job is done.`,
    html: shell({ heading, lines }),
  };
}
