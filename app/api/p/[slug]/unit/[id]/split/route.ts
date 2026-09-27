import { unitSplitRoute } from '@/lib/api/handlers';

export const dynamic = 'force-dynamic';

/**
 * POST /api/p/:slug/unit/:id/split -> retire the unit, mint two children,
 * record the lineage. See unitSplitRoute() in lib/api/handlers.ts.
 */
export async function POST(
  req: Request,
  ctx: { params: Promise<{ slug: string; id: string }> },
) {
  const { slug, id } = await ctx.params;
  return unitSplitRoute(slug, id, req);
}
