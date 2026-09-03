import type { APIRoute } from 'astro';
import { getSupabase } from '../../../lib/supabase';

export const POST: APIRoute = async (ctx) => {
  const { client } = getSupabase(ctx);
  await client.auth.signOut();
  return ctx.redirect('/login');
};
