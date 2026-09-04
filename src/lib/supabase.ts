import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import type { APIContext } from 'astro';

export type Role = 'teacher' | 'master';

export interface Profile {
  id: string;
  full_name: string;
  role: Role;
  class_name: string | null;
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

function getCookie(ctx: APIContext, name: string): string | null {
  const m = (ctx.request.headers.get('cookie') ?? '').match(
    new RegExp(`(?:^|; )${name}=([^;]*)`),
  );
  return m ? decodeURIComponent(m[1]) : null;
}

function getAccessToken(ctx: APIContext): string | null {
  return getCookie(ctx, 'sb-access-token');
}

export function getAuthTokens(ctx: APIContext): {
  access_token: string;
  refresh_token: string;
} | null {
  const access_token = getCookie(ctx, 'sb-access-token');
  const refresh_token = getCookie(ctx, 'sb-refresh-token');
  if (!access_token || !refresh_token) return null;
  return { access_token, refresh_token };
}

export async function setAuthSession(
  ctx: APIContext,
  client: SupabaseClient,
): Promise<boolean> {
  const tokens = getAuthTokens(ctx);
  if (!tokens) return false;
  const { error } = await client.auth.setSession(tokens);
  return !error;
}

export function getSupabase(ctx: APIContext, opts?: { public?: boolean }): AppSupabase {
  const { url, anonKey } = readConfig();
  // Halaman publik tidak boleh meneruskan cookie auth: token kadaluarsa
  // membuat PostgREST menolak request (401) alih-alih fallback ke anon.
  const token = opts?.public ? null : getAccessToken(ctx);
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
    .select('id, full_name, role, class_name, created_at')
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
