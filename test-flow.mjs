// Test the full ACP flow: init → session/new → session/prompt → updates

import { spawn } from 'child_process';
import { createInterface } from 'readline';

const proc = spawn('npx', ['@zed-industries/claude-code-acp'], {
  cwd: '/home/sprite',
  stdio: ['pipe', 'pipe', 'inherit']
});

const rl = createInterface({ input: proc.stdout });
let sessionId = null;
let messageCount = 0;

rl.on('line', (line) => {
  try {
    const msg = JSON.parse(line);

    // Response to our request
    if (msg.id && msg.result !== undefined) {
      console.log(`[RESP ${msg.id}]`, JSON.stringify(msg.result).slice(0, 100));

      if (msg.id === 1) {
        console.log('\n=== Initialized, creating session ===\n');
        send({ jsonrpc: '2.0', id: 2, method: 'session/new', params: { cwd: '/home/sprite', mcpServers: [] }});
      }
      else if (msg.id === 2 && msg.result?.sessionId) {
        sessionId = msg.result.sessionId;
        console.log(`\n=== Got session ${sessionId}, sending prompt ===\n`);
        send({ jsonrpc: '2.0', id: 3, method: 'session/prompt', params: {
          sessionId,
          prompt: [{ type: 'text', text: 'just say "hello world", nothing else' }]
        }});
      }
      else if (msg.id === 3) {
        console.log(`\n=== Prompt complete: ${msg.result?.stopReason} ===`);
        console.log(`Total updates received: ${messageCount}`);
        setTimeout(() => process.exit(0), 1000);
      }
    }
    // Notification (no id)
    else if (msg.method && !msg.id) {
      messageCount++;
      if (msg.method === 'session/update') {
        const update = msg.params?.update;
        if (update?.sessionUpdate === 'agent_message_chunk') {
          process.stdout.write(update.content?.text || '');
        } else {
          console.log(`[UPDATE] ${update?.sessionUpdate}`);
        }
      } else {
        console.log(`[NOTIF] ${msg.method}`);
      }
    }
    // Request from agent (has method AND id)
    else if (msg.method && msg.id) {
      console.log(`\n[AGENT REQUEST] ${msg.method} (id: ${msg.id})`);

      if (msg.method === 'session/request_permission') {
        // Auto-approve for testing
        const options = msg.params?.options || [];
        const allowOption = options.find(o => o.kind === 'allow_once');
        if (allowOption) {
          console.log(`  Auto-approving with option: ${allowOption.name}`);
          send({ jsonrpc: '2.0', id: msg.id, result: { outcome: { outcome: 'selected', optionId: allowOption.optionId }}});
        }
      }
    }
  } catch (e) {
    console.log('[RAW]', line.slice(0, 100));
  }
});

function send(msg) {
  console.log('[SEND]', JSON.stringify(msg).slice(0, 80));
  proc.stdin.write(JSON.stringify(msg) + '\n');
}

// Start with initialize
send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: 1, capabilities: {} }});

// Exit after 60s
setTimeout(() => {
  console.log('\n=== Timeout ===');
  process.exit(1);
}, 60000);
