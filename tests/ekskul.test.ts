import { describe, expect, it } from 'bun:test';
import {
  getThursdayOfWeek,
  getAdjacentThursday,
  formatKamisLabel,
  getEkskulStatusBadge,
} from '../src/lib/ekskul';

describe('ekskul helper functions', () => {
  it('correctly finds the Thursday of a given week in Asia/Jakarta', () => {
    // 2026-11-05 is Thursday
    const thursday = new Date(Date.UTC(2026, 10, 5, 4, 0, 0));
    expect(getThursdayOfWeek(thursday)).toBe('2026-11-05');

    // 2026-11-02 is Monday
    const monday = new Date(Date.UTC(2026, 10, 2, 4, 0, 0));
    expect(getThursdayOfWeek(monday)).toBe('2026-11-05');

    // 2026-11-06 is Friday
    const friday = new Date(Date.UTC(2026, 10, 6, 4, 0, 0));
    expect(getThursdayOfWeek(friday)).toBe('2026-11-05');

    // 2026-11-08 is Sunday
    const sunday = new Date(Date.UTC(2026, 10, 8, 4, 0, 0));
    expect(getThursdayOfWeek(sunday)).toBe('2026-11-05');
  });

  it('shifts Thursday by week offset', () => {
    expect(getAdjacentThursday('2026-11-05', 1)).toBe('2026-11-12');
    expect(getAdjacentThursday('2026-11-05', -1)).toBe('2026-10-29');
    expect(getAdjacentThursday('2026-11-05', 0)).toBe('2026-11-05');
  });

  it('formats Indonesian Thursday date label', () => {
    const label = formatKamisLabel('2026-11-05');
    expect(label).toContain('Kamis');
    expect(label).toContain('5');
    expect(label).toContain('November');
    expect(label).toContain('2026');
  });

  it('returns proper badge config for ekskul statuses', () => {
    expect(getEkskulStatusBadge('paid').label).toBe('LUNAS');
    expect(getEkskulStatusBadge('unpaid').label).toBe('TUNGGAKAN');
    expect(getEkskulStatusBadge('absent').label).toBe('TIDAK MASUK');
    expect(getEkskulStatusBadge(null).label).toBe('BELUM DICATAT');
  });
});
