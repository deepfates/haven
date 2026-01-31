// Test the bridge WebSocket connection

import WebSocket from 'ws';

const ws = new WebSocket('ws://localhost:8080');
let sessionId = null;

ws.on('open', () => {
  console.log('Connected to bridge');
  // Create a session
  send({ jsonrpc: '2.0', id: 1, method: 'session/new', params: {} });
});

ws.on('message', (data) => {
  try {
    const msg = JSON.parse(data.toString());

    // Response
    if (msg.id && msg.result !== undefined) {
      console.log(`[RESP ${msg.id}]`, JSON.stringify(msg.result).slice(0, 100));

      if (msg.id === 1 && msg.result?.sessionId) {
        sessionId = msg.result.sessionId;
        console.log(`Session created: ${sessionId}`);
        console.log('Waiting for session/ready...');
      }
      else if (msg.id === 2 && msg.result?.stopReason) {
        console.log(`\n=== Prompt complete: ${msg.result.stopReason} ===`);
        setTimeout(() => process.exit(0), 500);
      }
    }
    // Notification
    else if (msg.method && !msg.id) {
      if (msg.method === 'session/ready') {
        console.log(`Session ready: ${msg.params?.sessionId}`);
        console.log('\nSending prompt...');
        send({ jsonrpc: '2.0', id: 2, method: 'session/prompt', params: {
          sessionId: msg.params?.sessionId || sessionId,
          prompt: [{ type: 'text', text: 'just say "hello from bridge", nothing else' }]
        }});
      }
      else if (msg.method === 'session/update') {
        const update = msg.params?.update;
        if (update?.sessionUpdate === 'agent_message_chunk') {
          process.stdout.write(update.content?.text || '');
        } else {
          console.log(`[UPDATE] ${update?.sessionUpdate}`);
        }
      }
      else {
        console.log(`[NOTIF] ${msg.method}`, msg.params?.sessionId || '');
      }
    }
    // Request from agent
    else if (msg.method && msg.id) {
      console.log(`\n[AGENT REQUEST] ${msg.method} (id: ${msg.id})`);
      if (msg.method === 'session/request_permission') {
        const options = msg.params?.options || [];
        const allowOption = options.find(o => o.kind === 'allow_once');
        if (allowOption) {
          console.log(`  Auto-approving: ${allowOption.name}`);
          send({ jsonrpc: '2.0', id: msg.id, result: { outcome: { outcome: 'selected', optionId: allowOption.optionId }}});
        }
      }
    }
  } catch (e) {
    console.log('[RAW]', data.toString().slice(0, 100));
  }
});

ws.on('error', (err) => {
  console.error('WebSocket error:', err.message);
  process.exit(1);
});

function send(msg) {
  console.log('[SEND]', JSON.stringify(msg).slice(0, 80));
  ws.send(JSON.stringify(msg));
}

setTimeout(() => {
  console.log('\n=== Timeout ===');
  process.exit(1);
}, 120000);
