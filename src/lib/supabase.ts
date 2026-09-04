import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import type { APIContext } from 'astro';

export type Role = 'teacher' | 'master';

export interface Profile {
  id: string;
  full_name: string;
  role: Role;
  created_at: string;
}

export interface AppSupabase {
  client: SupabaseClient;
  url: string;
  anonKey: string;
}

function readConfig(): { url: string; anonKey: string } {
  const url = import.meta.env.PUBLIC_SUPABASE_URL ?? '';
  const anonKey = import.meta.env.PUBLIC_SUPABASE_ANON_KEY ?? '';

  if (!url || !anonKey) {
    throw new Error(
      'Supabase env missing. Set PUBLIC_SUPABASE_URL and PUBLIC_SUPABASE_ANON_KEY.',
    );
  }
  return { url, anonKey };
}

function getAccessToken(ctx: APIContext): string | null {
  const m = (ctx.request.headers.get('cookie') ?? '').match(/(?:^|; )sb-access-token=([^;]*)/);
  return m ? decodeURIComponent(m[1]) : null;
}

export function getSupabase(ctx: APIContext): AppSupabase {
  const { url, anonKey } = readConfig();
  const token = getAccessToken(ctx);
  const headers: Record<string, string> = {};
  if (token) headers['Authorization'] = `Bearer ${token}`;
  const client = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers },
  });
  return { client, url, anonKey };
}

export async function getCurrentUser(ctx: APIContext) {
  const token = getAccessToken(ctx);
  if (!token) return null;
  const { client } = getSupabase(ctx);
  const { data } = await client.auth.getUser(token);
  return data.user ?? null;
}

export async function getCurrentProfile(ctx: APIContext): Promise<Profile | null> {
  const user = await getCurrentUser(ctx);
  if (!user) return null;
  const { client } = getSupabase(ctx);
  const { data } = await client
    .from('profiles')
    .select('id, full_name, role, created_at')
    .eq('id', user.id)
    .single();
  return data as Profile | null;
}

export async function requireRole(ctx: APIContext, role: Role): Promise<Profile> {
  const profile = await getCurrentProfile(ctx);
  if (!profile) {
    return ctx.redirect('/login') as unknown as Profile;
  }
  // Master can do everything a teacher can.
  if (profile.role !== role && !(role === 'teacher' && profile.role === 'master')) {
    return ctx.redirect('/') as unknown as Profile;
  }
  return profile;
}

export async function requireMaster(ctx: APIContext): Promise<Profile> {
  return requireRole(ctx, 'master');
}
