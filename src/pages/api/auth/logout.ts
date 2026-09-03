import type { APIRoute } from 'astro';


export const POST: APIRoute = async (ctx) => {
  ctx.cookies.delete('sb-access-token', { path: '/' });
  ctx.cookies.delete('sb-refresh-token', { path: '/' });
  return ctx.redirect('/login');
};
