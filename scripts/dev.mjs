#!/usr/bin/env node
// `npm run dev`: server and web dev servers side by side (npm has no --parallel).
// If either exits, stop the other so a crashed server never leaves Vite orphaned.
import { spawn } from 'node:child_process';

// On Windows kill() ends only the cmd shell, not the dev server under it.
const stop = (child) =>
  process.platform === 'win32' ? spawn('taskkill', ['/pid', String(child.pid), '/T', '/F']) : child.kill();

const children = ['@patogh/server', '@patogh/web'].map((ws) =>
  spawn(`npm run dev -w ${ws}`, { stdio: 'inherit', shell: true }),
);
for (const child of children) {
  child.on('exit', (code) => {
    process.exitCode ||= code ?? 1;
    for (const other of children) if (other !== child && other.exitCode === null) stop(other);
  });
}
