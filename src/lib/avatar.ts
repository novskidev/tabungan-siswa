// Warna avatar inisial otomatis dari nama siswa.
const PALETTES: [string, string][] = [
  ['#FFE1EC', '#D6336C'],
  ['#E3F4FF', '#0E7AC4'],
  ['#FFF3D1', '#B7791F'],
  ['#E2F8EC', '#1E9E5A'],
  ['#F1E6FF', '#7C3AED'],
  ['#FFE9D9', '#EA6A1F'],
];

export function avatarStyle(fullName: string): { background: string; color: string } {
  let hash = 0;
  for (let i = 0; i < fullName.length; i++) {
    hash = (hash * 31 + fullName.charCodeAt(i)) >>> 0;
  }
  const [background, color] = PALETTES[hash % PALETTES.length];
  return { background, color };
}

export function initials(fullName: string): string {
  const parts = fullName.trim().split(/\s+/);
  return ((parts[0]?.[0] ?? '') + (parts[1]?.[0] ?? '')).toUpperCase();
}
