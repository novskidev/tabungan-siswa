import type { APIRoute } from 'astro';
import { getSupabase } from '../../../lib/supabase';

export const POST: APIRoute = async (ctx) => {
  const form = await ctx.request.formData();
  const email = String(form.get('email') ?? '').trim();
  const password = String(form.get('password') ?? '');

  if (!email || !password) {
    return ctx.redirect('/login?error=empty');
  }

  const { client } = getSupabase(ctx);
  const { data, error } = await client.auth.signInWithPassword({
    email,
    password,
  });

  if (error || !data.session) {
    const code = error?.message.toLowerCase().includes('invalid login')
      ? 'bad-pass'
      : 'auth-failed';
    return ctx.redirect(`/login?error=${code}`);
  }

  const headers = new Headers();
  headers.append(
    'Set-Cookie',
    `sb-access-token=${encodeURIComponent(data.session.access_token)}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${60 * 60 * 24 * 7}`,
  );
  headers.append(
    'Set-Cookie',
    `sb-refresh-token=${encodeURIComponent(data.session.refresh_token)}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${60 * 60 * 24 * 30}`,
  );
  headers.set('Location', '/dashboard');
  return new Response(null, { status: 302, headers });
};
