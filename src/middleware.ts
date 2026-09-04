import { defineMiddleware } from 'astro:middleware';
import { getCurrentProfile, type Role } from './lib/supabase';

const PROTECTED: { prefix: string; role: Role }[] = [
  { prefix: '/master', role: 'master' },
  { prefix: '/guru', role: 'teacher' },
];

const PROTECTED_PREFIXES = [
  '/api/',
];

export const onRequest = defineMiddleware(async (ctx, next) => {
  const path = ctx.url.pathname;

  // Allow public routes.
  if (
    path === '/' ||
    path === '/login' ||
    path === '/dashboard' ||
    path === '/ganti-password' ||
    path.startsWith('/siswa/') ||
    path.startsWith('/_astro/') ||
    path.startsWith('/favicon') ||
    path === '/api/auth/login' ||
    path === '/api/auth/logout'
  ) {
    return next();
  }

  // Find matching protected route.
  const match = PROTECTED.find((p) => path.startsWith(p.prefix));
  if (!match && !PROTECTED_PREFIXES.some((p) => path.startsWith(p))) {
    return next();
  }

  // Auth required.
  const profile = await getCurrentProfile(ctx);
  if (!profile) {
    return ctx.redirect('/login');
  }

  // Master passes teacher gates (handled in requireRole); middleware mirrors it.
  if (match && profile.role !== match.role && !(match.role === 'teacher' && profile.role === 'master')) {
    return ctx.redirect('/');
  }

  // Stash profile for the page frontmatter.
  ctx.locals.profile = profile;
  return next();
});
