import type { EkskulStatus } from '../types/database';

export const APP_TZ = 'Asia/Jakarta';

/**
 * Returns the YYYY-MM-DD date string of Thursday of the week for a given date in Asia/Jakarta.
 * A week runs from Monday to Sunday.
 */
export function getThursdayOfWeek(date: Date = new Date(), tz: string = APP_TZ): string {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: tz,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(date); // 'YYYY-MM-DD'

  const [y, m, d] = parts.split('-').map(Number);
  // Construct date at UTC noon to avoid any DST / midnight boundary shifts
  const localDate = new Date(Date.UTC(y, m - 1, d, 12, 0, 0));
  
  // getUTCDay(): 0 is Sunday, 1 is Monday ... 6 is Saturday
  const utcDay = localDate.getUTCDay();
  const isoDay = (utcDay + 6) % 7 + 1; // 1 = Monday ... 4 = Thursday ... 7 = Sunday
  const diffToThursday = 4 - isoDay;

  localDate.setUTCDate(localDate.getUTCDate() + diffToThursday);
  return localDate.toISOString().slice(0, 10);
}

/**
 * Shifts a Thursday date by a given number of weeks (+1 for next Thursday, -1 for previous).
 */
export function getAdjacentThursday(thursdayStr: string, weeksOffset: number): string {
  const [y, m, d] = thursdayStr.split('-').map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d + weeksOffset * 7, 12, 0, 0));
  return dt.toISOString().slice(0, 10);
}

/**
 * Formats a Thursday date string into localized Indonesian text (e.g. "Kamis, 5 November 2026").
 */
export function formatKamisLabel(thursdayStr: string): string {
  const [y, m, d] = thursdayStr.split('-').map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d, 12, 0, 0));
  return new Intl.DateTimeFormat('id-ID', {
    weekday: 'long',
    day: 'numeric',
    month: 'long',
    year: 'numeric',
    timeZone: 'UTC',
  }).format(dt);
}

/**
 * Returns badge styling and label for an ekskul status.
 */
export function getEkskulStatusBadge(status: EkskulStatus | null): { label: string; class: string } {
  switch (status) {
    case 'paid':
      return {
        label: 'LUNAS',
        class: 'bg-emerald-100 text-emerald-800 border-emerald-300',
      };
    case 'unpaid':
      return {
        label: 'TUNGGAKAN',
        class: 'bg-amber-100 text-amber-800 border-amber-300',
      };
    case 'absent':
      return {
        label: 'TIDAK MASUK',
        class: 'bg-gray-100 text-gray-700 border-gray-300',
      };
    default:
      return {
        label: 'BELUM DICATAT',
        class: 'bg-blue-50 text-blue-700 border-blue-200',
      };
  }
}
