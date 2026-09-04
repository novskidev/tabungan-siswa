const CODE_ALPHABET = 'abcdefghjkmnpqrstuvwxyz23456789';

export function defaultPinForClass(className: string): string {
  const m = className.trim().match(/^\d/);
  return (m ? m[0] : '0').repeat(4);
}

export function generatePublicCode(length = 6): string {
  const buf = new Uint8Array(length);
  crypto.getRandomValues(buf);
  let out = '';
  for (const b of buf) out += CODE_ALPHABET[b % CODE_ALPHABET.length];
  return out;
}

export function isValidPin(pin: string): boolean {
  return /^\d{4}$/.test(pin);
}
