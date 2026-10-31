export function isElectron(): boolean {
  return typeof window !== 'undefined' && typeof window.patogh !== 'undefined';
}

export function isElectronMac(): boolean {
  return isElectron() && window.patogh?.platform === 'darwin';
}

export function getElectronAPI(): PatoghElectronAPI | null {
  return window.patogh ?? null;
}
