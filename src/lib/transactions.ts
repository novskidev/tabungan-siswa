import type { SupabaseClient } from '@supabase/supabase-js';
import type { APIContext } from 'astro';
import { getSupabase } from './supabase';
import type { StudentBalance, TransactionRow } from '../types/database';

const RP = new Intl.NumberFormat('id-ID', {
  style: 'currency',
  currency: 'IDR',
  minimumFractionDigits: 0,
  maximumFractionDigits: 0,
});

// Single timezone for the whole app. School context — teacher and parent are
// local, so we pin display to WIB. Database stores timestamptz in UTC; every
// formatter pins the visible wall-clock to Asia/Jakarta.
export const APP_TZ = 'Asia/Jakarta';

export function formatRupiah(n: number | string): string {
  const num = typeof n === 'string' ? Number(n) : n;
  if (!Number.isFinite(num)) return 'Rp0';
  return RP.format(num);
}

export async function getStudentBalance(
  ctx: APIContext,
  studentId: string,
): Promise<StudentBalance> {
  const { client } = getSupabase(ctx);
  const { data } = await client
    .from('transactions')
    .select('type, amount')
    .eq('student_id', studentId);

  let totalDeposit = 0;
  let totalWithdrawal = 0;
  for (const row of data ?? []) {
    const amt = Number(row.amount);
    if (row.type === 'deposit') totalDeposit += amt;
    else totalWithdrawal += amt;
  }
  return {
    totalDeposit,
    totalWithdrawal,
    balance: totalDeposit - totalWithdrawal,
  };
}

export async function getStudentTransactions(
  client: SupabaseClient,
  studentId: string,
  limit = 50,
): Promise<TransactionRow[]> {
  const { data } = await client
    .from('transactions')
    .select(
      'id, student_id, type, amount, note, created_by, created_at, correction_of, correction_reason, corrected_by, corrected_at, student:students(id, full_name, nis), creator:profiles!transactions_created_by_fkey(id, full_name)',
    )
    .eq('student_id', studentId)
    .order('created_at', { ascending: false })
    .limit(limit);
  return (data as unknown as TransactionRow[] | null) ?? [];
}

export async function getRecentTransactions(
  client: SupabaseClient,
  limit = 20,
): Promise<TransactionRow[]> {
  const { data } = await client
    .from('transactions')
    .select(
      'id, student_id, type, amount, note, created_by, created_at, correction_of, correction_reason, corrected_by, corrected_at, student:students(id, full_name, nis), creator:profiles!transactions_created_by_fkey(id, full_name)',
    )
    .order('created_at', { ascending: false })
    .limit(limit);
  return (data as unknown as TransactionRow[] | null) ?? [];
}

export interface DailySummary {
  count: number;
  totalDeposit: number;
  totalWithdrawal: number;
}

export async function getDailySummary(
  client: SupabaseClient,
  day: Date = new Date(),
): Promise<DailySummary> {
  // ponytail: SSR runs in UTC on Cloudflare Workers. The "Hari Ini" card has to
  // mean today in Asia/Jakarta, so we compute the day bounds there and back-convert.
  const fmt = new Intl.DateTimeFormat('en-CA', {
    timeZone: APP_TZ,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  });
  const dayKey = fmt.format(day);
  const [y, m, d] = dayKey.split('-').map(Number);
  const start = new Date(Date.UTC(y, m - 1, d, -7));
  const end = new Date(Date.UTC(y, m - 1, d + 1, -7));

  const { data } = await client
    .from('transactions')
    .select('type, amount')
    .gte('created_at', start.toISOString())
    .lt('created_at', end.toISOString());

  let totalDeposit = 0;
  let totalWithdrawal = 0;
  let count = 0;
  for (const row of (data ?? []) as { type: string; amount: string | number }[]) {
    const n = Number(row.amount) || 0;
    if (row.type === 'deposit') totalDeposit += n;
    else if (row.type === 'withdrawal') totalWithdrawal += n;
    count++;
  }
  return { count, totalDeposit, totalWithdrawal };
}

export interface CreateTransactionInput {
  studentId: string;
  type: 'deposit' | 'withdrawal';
  amount: number;
  note?: string | null;
}

export type CreateTransactionResult =
  | { ok: true; transaction: TransactionRow }
  | { ok: false; code: 'unauthenticated' | 'forbidden' | 'invalid' | 'insufficient' | 'not_found' | 'network'; message: string };

export async function createTransaction(
  ctx: APIContext,
  input: CreateTransactionInput,
): Promise<CreateTransactionResult> {
  const { client } = getSupabase(ctx);
  const { data, error } = await client.rpc('create_transaction', {
    p_student_id: input.studentId,
    p_type: input.type,
    p_amount: input.amount,
    p_note: input.note ?? null,
  });

  if (error) {
    const msg = (error.message ?? '').toLowerCase();
    if (msg.includes('insufficient')) {
      return { ok: false, code: 'insufficient', message: 'Saldo tidak mencukupi.' };
    }
    if (msg.includes('forbidden')) {
      return { ok: false, code: 'forbidden', message: 'Anda tidak punya akses.' };
    }
    if (msg.includes('amount') || msg.includes('invalid') || msg.includes('type')) {
      return { ok: false, code: 'invalid', message: 'Nominal atau jenis transaksi tidak valid.' };
    }
    if (msg.includes('student not found')) {
      return { ok: false, code: 'not_found', message: 'Siswa tidak ditemukan.' };
    }
    return { ok: false, code: 'network', message: 'Transaksi gagal disimpan. Silakan coba lagi.' };
  }

  return { ok: true, transaction: data as TransactionRow };
}

export function formatDateShort(iso: string): string {
  const d = new Date(iso);
  const date = d.toLocaleDateString('id-ID', {
    day: '2-digit',
    month: 'short',
    year: 'numeric',
    timeZone: APP_TZ,
  });
  const time = d.toLocaleTimeString('id-ID', {
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
    timeZone: APP_TZ,
  });
  return `${date} ${time}`;
}

export function dayKey(iso: string): string {
  const d = new Date(iso);
  // ponytail: SSR runs in Cloudflare Workers (UTC); compute "today"/"yesterday"
  // in the school timezone so day groups match what teachers and parents see.
  const fmt = new Intl.DateTimeFormat('en-CA', { timeZone: APP_TZ });
  const todayKey = fmt.format(new Date());
  const isoKey = fmt.format(d);
  if (todayKey === isoKey) return 'today';
  // Compute yesterday by subtracting one calendar day in the same timezone.
  const [y, m, dd] = todayKey.split('-').map(Number);
  const yesterday = new Date(Date.UTC(y, m - 1, dd - 1));
  const yesterdayKey = fmt.format(yesterday);
  if (yesterdayKey === isoKey) return 'yesterday';
  return isoKey;
}

export function dayLabel(key: string): string {
  if (key === 'today') return 'Hari Ini';
  if (key === 'yesterday') return 'Kemarin';
  return new Date(key).toLocaleDateString('id-ID', {
    day: '2-digit',
    month: 'long',
    year: 'numeric',
    timeZone: APP_TZ,
  });
}

export function groupByDay<T extends { created_at: string }>(
  rows: T[],
): { key: string; label: string; items: T[] }[] {
  const map = new Map<string, T[]>();
  for (const r of rows) {
    const k = dayKey(r.created_at);
    if (!map.has(k)) map.set(k, []);
    map.get(k)!.push(r);
  }
  return [...map.entries()].map(([key, items]) => ({
    key,
    label: dayLabel(key),
    items,
  }));
}

// Single timezone for the whole app is pinned at the top of this file.

export function formatDateLong(iso: string): string {
  return new Date(iso).toLocaleDateString('id-ID', {
    day: '2-digit',
    month: 'long',
    year: 'numeric',
    timeZone: APP_TZ,
  });
}

export function formatTimeShort(iso: string): string {
  return new Date(iso).toLocaleTimeString('id-ID', {
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
    timeZone: APP_TZ,
  });
}

export function formatTimestamp(iso: string): string {
  return `${formatDateLong(iso)} ${formatTimeShort(iso)}`;
}

export interface CorrectTransactionInput {
  originalId: string;
  reason: string;
}

export type CorrectTransactionResult =
  | { ok: true; transaction: TransactionRow }
  | { ok: false; code: 'unauthenticated' | 'forbidden' | 'invalid' | 'already_corrected' | 'insufficient' | 'not_found' | 'network'; message: string };

export async function correctTransaction(
  ctx: APIContext,
  input: CorrectTransactionInput,
): Promise<CorrectTransactionResult> {
  const { client } = getSupabase(ctx);
  const { data, error } = await client.rpc('correct_transaction', {
    p_original_id: input.originalId,
    p_reason: input.reason,
  });

  if (error) {
    const msg = (error.message ?? '').toLowerCase();
    if (msg.includes('forbidden')) {
      return { ok: false, code: 'forbidden', message: 'Anda tidak punya akses.' };
    }
    if (msg.includes('reason required') || msg.includes('invalid')) {
      return { ok: false, code: 'invalid', message: 'Alasan koreksi wajib diisi.' };
    }
    if (msg.includes('already corrected')) {
      return { ok: false, code: 'already_corrected', message: 'Transaksi ini sudah pernah dikoreksi.' };
    }
    if (msg.includes('balance already lower') || msg.includes('insufficient')) {
      return { ok: false, code: 'insufficient', message: 'Saldo sudah lebih kecil dari nominal, tidak bisa dikoreksi.' };
    }
    if (msg.includes('not found')) {
      return { ok: false, code: 'not_found', message: 'Transaksi tidak ditemukan.' };
    }
    return { ok: false, code: 'network', message: 'Koreksi gagal disimpan. Silakan coba lagi.' };
  }

  return { ok: true, transaction: data as TransactionRow };
}
