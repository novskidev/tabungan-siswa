export type Role = 'teacher' | 'master';

export type TransactionType = 'deposit' | 'withdrawal';

export interface StudentRow {
  id: string;
  nis: string | null;
  full_name: string;
  class_name: string;
  public_code: string;
  is_active: boolean;
  created_at: string;
  updated_at: string;
}

export interface TransactionRow {
  id: string;
  student_id: string;
  type: TransactionType;
  amount: string;
  note: string | null;
  created_by: string;
  created_at: string;
  correction_of: string | null;
  correction_reason: string | null;
  corrected_by: string | null;
  corrected_at: string | null;
  student?: { id: string; full_name: string; nis: string | null } | { id: string; full_name: string; nis: string | null }[] | null;
  creator?: { id: string; full_name: string } | { id: string; full_name: string }[] | null;
}

export function asStudent(t: TransactionRow['student']): { id: string; full_name: string; nis: string | null } | null {
  if (Array.isArray(t)) return t[0] ?? null;
  return t ?? null;
}

export function asCreator(t: TransactionRow['creator']): { id: string; full_name: string } | null {
  if (Array.isArray(t)) return t[0] ?? null;
  return t ?? null;
}

export interface StudentBalance {
  totalDeposit: number;
  totalWithdrawal: number;
  balance: number;
}

export interface PublicStudent {
  id: string;
  full_name: string;
  class_name: string;
  public_code: string;
}

export interface VerifiedSavings {
  student_id: string;
  full_name: string;
  class_name: string;
  balance: number;
  total_deposit: number;
  total_withdrawal: number;
}

export interface PublicHistoryItem {
  id: string;
  type: TransactionType;
  amount: string;
  note: string | null;
  created_at: string;
}
