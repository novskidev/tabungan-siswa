export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[];

export type Role = 'teacher' | 'parent';

export type TransactionType = 'deposit' | 'withdrawal';

export interface Database {
  public: {
    Tables: {
      profiles: {
        Row: {
          id: string;
          full_name: string;
          role: Role;
          created_at: string;
        };
        Insert: {
          id: string;
          full_name: string;
          role: Role;
          created_at?: string;
        };
        Update: Partial<{
          full_name: string;
          role: Role;
        }>;
      };
      classes: {
        Row: {
          id: string;
          name: string;
          academic_year: string;
          created_at: string;
        };
        Insert: {
          id?: string;
          name: string;
          academic_year: string;
          created_at?: string;
        };
        Update: Partial<{
          name: string;
          academic_year: string;
        }>;
      };
      students: {
        Row: {
          id: string;
          nis: string;
          full_name: string;
          class_id: string;
          parent_id: string | null;
          is_active: boolean;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          nis: string;
          full_name: string;
          class_id: string;
          parent_id?: string | null;
          is_active?: boolean;
          created_at?: string;
          updated_at?: string;
        };
        Update: Partial<{
          nis: string;
          full_name: string;
          class_id: string;
          parent_id: string | null;
          is_active: boolean;
        }>;
      };
      transactions: {
        Row: {
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
        };
        Insert: {
          id?: string;
          student_id: string;
          type: TransactionType;
          amount: string;
          note?: string | null;
          created_by: string;
          created_at?: string;
          correction_of?: string | null;
          correction_reason?: string | null;
          corrected_by?: string | null;
          corrected_at?: string | null;
        };
        Update: Partial<{
          note: string | null;
        }>;
      };
    };
    Functions: {
      create_transaction: {
        Args: {
          p_student_id: string;
          p_type: TransactionType;
          p_amount: number | string;
          p_note?: string | null;
        };
        Returns: {
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
        };
      };
      correct_transaction: {
        Args: {
          p_original_id: string;
          p_reason: string;
        };
        Returns: {
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
        };
      };
    };
  };
}

export interface StudentClassRef {
  id: string;
  name: string;
  academic_year: string;
}

export interface StudentParentRef {
  id: string;
  full_name: string;
}

export interface StudentWithRelations {
  id: string;
  nis: string;
  full_name: string;
  class_id: string;
  parent_id: string | null;
  created_at: string;
  updated_at: string;
  class: StudentClassRef | StudentClassRef[] | null;
  parent: StudentParentRef | StudentParentRef[] | null;
}

export function asClass(s: StudentWithRelations['class']): StudentClassRef | null {
  if (Array.isArray(s)) return s[0] ?? null;
  return s ?? null;
}

export function asParent(s: StudentWithRelations['parent']): StudentParentRef | null {
  if (Array.isArray(s)) return s[0] ?? null;
  return s ?? null;
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
  student?: { id: string; full_name: string; nis: string } | { id: string; full_name: string; nis: string }[] | null;
  creator?: { id: string; full_name: string } | { id: string; full_name: string }[] | null;
}

export function asStudent(t: TransactionRow['student']): { id: string; full_name: string; nis: string } | null {
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
