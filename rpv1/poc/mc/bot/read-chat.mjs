#!/usr/bin/env node
/**
 * RPV1 fake-player reader.
 *
 * spark's command output only ever goes to the in-game chat, so plain RCON can
 * never see it. This script logs a headless protocol client (mineflayer) into
 * the offline-mode test server, gets opped by the harness, runs the given
 * commands and prints/writes everything that came back in chat.
 *
 *   node read-chat.mjs --user rpvbot --ready <file> --start <file> \
 *        --cmd "/spark tps" --cmd "/spark health" --wait 6 --out <file>
 *
 * Handshake with the harness:
 *   spawn        -> writes <ready> (harness then runs: op <user>)
 *   <start> seen -> sends the commands (harness creates it once op is applied)
 *   after <wait> -> prints "BOT_CHAT" + the collected lines, writes <out>, quits
 */
import fs from 'node:fs';
import mineflayer from 'mineflayer';

const argv = process.argv.slice(2);
const opt = (name, def) => {
    const i = argv.indexOf('--' + name);
    return i >= 0 && i + 1 < argv.length ? argv[i + 1] : def;
};
const optAll = (name) => {
    const out = [];
    argv.forEach((a, i) => { if (a === '--' + name && i + 1 < argv.length) out.push(argv[i + 1]); });
    return out;
};
// --cmds "a,b" is the shell-friendly form (PowerShell's -ArgumentList joins
// with spaces, so a value containing a space must not be its own argv entry)
const stripQuotes = (s) => s.replace(/^"|"$/g, '').trim();

const host = opt('host', '127.0.0.1');
const port = Number(opt('port', '25565'));
const user = opt('user', 'rpvbot');
const version = opt('version', '1.21.1');
const readyFile = opt('ready', '');
const startFile = opt('start', '');
const outFile = opt('out', '');
const waitSec = Number(opt('wait', '6'));
const startTimeoutMs = Number(opt('start-timeout', '25')) * 1000;
const commands = optAll('cmd').map(stripQuotes).filter(Boolean);
const cmdsJoined = stripQuotes(opt('cmds', ''));
if (cmdsJoined) {
    for (const c of cmdsJoined.split(',')) {
        const s = stripQuotes(c);
        if (s) commands.push(s);
    }
}

const lines = [];
const bot = mineflayer.createBot({ host, port, username: user, version, auth: 'offline' });
let sent = false;

bot.on('spawn', () => {
    const uuid = (bot.player && bot.player.uuid) || '';
    console.log(`BOT_SPAWN user=${user} uuid=${uuid}`);
    if (readyFile) fs.writeFileSync(readyFile, uuid || user);

    const t0 = Date.now();
    const poll = setInterval(() => {
        const ready = !startFile || fs.existsSync(startFile);
        if (ready || Date.now() - t0 > startTimeoutMs) {
            clearInterval(poll);
            sent = true;
            for (const c of commands) {
                const cmd = c.startsWith('/') ? c : '/' + c;
                console.log(`BOT_CMD ${cmd}`);
                bot.chat(cmd);
            }
        }
    }, 200);
});

bot.on('message', (jsonMsg) => {
    let text = '';
    try { text = jsonMsg.toString(); } catch { text = String(jsonMsg); }
    if (text && text.trim()) lines.push(text.trim());
});

// spark may emit some of its output outside normal chat (action bar / titles /
// raw component packets). Raw packet dumps are very noisy, so they are opt-in.
const RAW = argv.includes('--raw');
const record = (kind, payload) => {
    if (!RAW) return;
    let s;
    try {
        s = typeof payload === 'string' ? payload : JSON.stringify(payload);
    } catch { s = String(payload); }
    if (s && s.trim()) lines.push(`[${kind}] ${s.trim()}`);
};
bot.on('actionBar', (m) => record('actionbar', m && m.toString ? m.toString() : m));
bot.on('title', (m) => record('title', m && m.toString ? m.toString() : m));
bot.on('subtitle', (m) => record('subtitle', m && m.toString ? m.toString() : m));
if (bot._client) {
    for (const p of ['system_chat', 'chat', 'player_chat', 'set_action_bar_text',
                     'set_title_text', 'set_subtitle_text', 'profileless_chat']) {
        bot._client.on(p, (data) => record('pkt:' + p, data));
    }
}
bot.on('kicked', (r) => console.log('BOT_KICKED', typeof r === 'string' ? r : JSON.stringify(r)));
bot.on('error', (e) => console.log('BOT_ERROR', e.message));
bot.on('end', (r) => console.log('BOT_END', r || ''));

const finish = () => {
    const text = lines.join('\n');
    // spark prints a label on one line and the values on the next; turn that
    // into a machine-readable summary so the harness does not have to scrape.
    const labels = [
        ['tps', /TPS from last/],
        ['tick_ms', /Tick durations/],
        ['cpu', /CPU usage from last/],
        ['memory', /Memory usage/],
    ];
    const clean = (s) => s.replace(/^\[[^\]]*\]\s*/, '').trim();   // strip the [⚡] prefix
    const summary = [];
    for (let i = 0; i < lines.length; i++) {
        const cur = clean(lines[i]);
        for (const [key, re] of labels) {
            if (re.test(cur)) {
                const value = clean(lines[i + 1] || '');
                if (value && !/^\[pkt:/.test(lines[i + 1] || '')) summary.push(`${key}=${value}`);
            }
        }
    }
    console.log(`BOT_SENT_COMMANDS ok=${sent}`);
    console.log(`BOT_CHAT_LINES ${lines.length}`);
    console.log('SPARK_SUMMARY_BEGIN');
    if (summary.length) summary.forEach((s) => console.log(s));
    else console.log('(no spark summary lines recognised)');
    console.log('SPARK_SUMMARY_END');
    console.log('--- BOT_CHAT_BEGIN ---');
    console.log(text);
    console.log('--- BOT_CHAT_END ---');
    if (outFile) {
        fs.writeFileSync(outFile,
            `# user=${user} commands=${commands.join(' | ')}\n` +
            `# summary\n${summary.join('\n')}\n\n# raw chat\n${text}\n`);
    }
    try { bot.quit(); } catch { /* ignore */ }
    setTimeout(() => process.exit(0), 300);
};

// wait for commands + a collection window; if we never spawned, bail out anyway
setTimeout(finish, Math.max(waitSec * 1000 + 4000, 12000));
