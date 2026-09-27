'use client';

import { useEffect, useRef, useState } from 'react';
import { DISCLAIMER, decode3D, parse, type Ulpin3DParts } from '@/lib/ulpin';

/**
 * The ULPIN card.
 *
 * Renders the identifier broken into its segments so the hierarchy is legible,
 * and carries the disclaimer inline -- not in a tooltip -- because presenting an
 * invented identifier in the visual language of a government one, without
 * saying so, is precisely the failure mode worth avoiding here.
 *
 * FORMAT-DETECTING: every entity this application mints going forward carries
 * a 3D ULPIN (`decode3D` succeeds), rendered as parcel / building / level /
 * unit / check. An identifier that does not parse as one is the OLD 7-group
 * format, reached through `legacy_id` for an already-issued deed or a
 * bookmarked URL -- it falls back to the original 7-segment rendering rather
 * than being shown as broken.
 */

const SEGMENT_LABELS_LEGACY = ['State', 'District', 'Scheme', 'Parcel', 'Bldg', 'Floor', 'Unit'];

function levelLabel3D(level: Ulpin3DParts['level']): string {
  if (!level) return '';
  switch (level.kind) {
    case 'ground': return 'Ground';
    case 'floor': return `Floor ${level.n}`;
    case 'basement': return `Basement ${level.n}`;
    case 'airRights': return `Air rights ${level.n}`;
    default: return '';
  }
}

function unitLabel3D(unit: Ulpin3DParts['unit']): string {
  if (!unit) return '';
  if (unit.kind === 'parking') return `Parking ${unit.n}`;
  if (unit.kind === 'common') return `Common area ${unit.n}`;
  return `Unit ${unit.n}`;
}

interface Segment {
  text: string;
  label: string;
  tinted: boolean;
}

/** Break a valid 3D ULPIN into its display segments: parcel/building/level/unit/check. */
function segments3D(ulpin: string, parts: Ulpin3DParts): Segment[] {
  const raw = ulpin.trim().toUpperCase().split('-');
  const out: Segment[] = [{ text: parts.ulpin14, label: 'Parcel (ULPIN14)', tinted: false }];
  let i = 1;
  if (parts.building !== undefined) { out.push({ text: raw[i], label: 'Building', tinted: true }); i += 1; }
  if (parts.level) { out.push({ text: raw[i], label: levelLabel3D(parts.level), tinted: true }); i += 1; }
  if (parts.unit) { out.push({ text: raw[i], label: unitLabel3D(parts.unit), tinted: true }); i += 1; }
  out.push({ text: parts.check, label: 'Check', tinted: false });
  return out;
}

export default function UlpinCard({
  ulpin, ulpin14Source, legacyId,
}: {
  ulpin: string;
  /** 'synthetic' | 'official' -- present when this card's entity carries a ulpin14. */
  ulpin14Source?: string;
  /** The pre-3D-ULPIN identifier, shown as a secondary reference when present. */
  legacyId?: string;
}) {
  const [copied, setCopied] = useState(false);
  const parts3d = decode3D(ulpin);
  // 'any' codes for the legacy fallback: this card renders an identifier the
  // server has already minted for the project on screen. Asserting the demo
  // project's district here would blank the card for every other AOI.
  const partsLegacy = parts3d ? null : parse(ulpin, 'any');
  const segments = parts3d ? segments3D(ulpin, parts3d) : null;
  const legacySegments = partsLegacy ? ulpin.split('-') : null;

  // The 1.4 s "Copied" acknowledgement must not fire setCopied on an
  // unmounted card if the user dismissed it within the window. The
  // unmount cleanup below clears the timer; the reschedule path also
  // clears the prior one, so a second click resets the window instead
  // of stacking.
  const resetTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(() => () => {
    if (resetTimer.current) clearTimeout(resetTimer.current);
  }, []);

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(ulpin);
      setCopied(true);
      if (resetTimer.current) clearTimeout(resetTimer.current);
      resetTimer.current = setTimeout(() => setCopied(false), 1400);
    } catch {
      /* clipboard blocked; the identifier is selectable on screen anyway */
    }
  };

  return (
    <div className="glass-soft rounded-md p-2.5">
      <div className="flex items-center justify-between">
        <span className="panel-title">{parts3d ? '3D ULPIN' : 'ULPIN'}</span>
        <button
          type="button"
          onClick={copy}
          className="rounded px-1.5 py-0.5 text-[10px] text-[rgb(var(--muted))] tint-hover hover:text-[rgb(var(--ink))]"
        >
          {copied ? 'Copied' : 'Copy'}
        </button>
      </div>

      <div className="mt-1.5 flex flex-wrap items-end gap-x-1 gap-y-1 font-mono text-[13px] leading-none text-[rgb(var(--ink))]">
        {segments
          ? segments.map((seg, i) => (
            <span key={`${seg.text}-${i}`} className="flex flex-col items-center gap-0.5">
              <span className="text-[8px] uppercase tracking-wide text-[rgb(var(--muted))]">
                {seg.label}
              </span>
              <span
                className={
                  seg.tinted
                    ? 'rounded bg-[rgb(var(--tint)/0.15)] px-1 py-0.5 text-[rgb(var(--ink))]'
                    : 'px-0.5 py-0.5'
                }
              >
                {seg.text}
              </span>
            </span>
          ))
          : legacySegments?.map((seg, i) => (
            <span key={`${seg}-${i}`} className="flex flex-col items-center gap-0.5">
              <span className="text-[8px] uppercase tracking-wide text-[rgb(var(--muted))]">
                {SEGMENT_LABELS_LEGACY[i] ?? ''}
              </span>
              <span
                className={
                  i >= 3
                    ? 'rounded bg-[rgb(var(--tint)/0.15)] px-1 py-0.5 text-[rgb(var(--ink))]'
                    : 'px-0.5 py-0.5'
                }
              >
                {seg}
              </span>
            </span>
          ))}
      </div>

      {partsLegacy ? (
        <div className="mt-1.5 text-[10px] text-[rgb(var(--muted))]">
          parcel {partsLegacy.parcel}
          {partsLegacy.building !== undefined ? ` · building ${partsLegacy.building}` : ''}
          {partsLegacy.floor !== undefined ? ` · level ${partsLegacy.floor}` : ''}
          {partsLegacy.unit !== undefined ? ` · unit ${partsLegacy.unit}` : ''}
        </div>
      ) : null}

      {ulpin14Source === 'synthetic' ? (
        <div className="mt-1.5 text-[10px] text-[rgb(var(--muted))]">
          ULPIN14: synthetic (demo) -- no official register issued this parcel identifier.
        </div>
      ) : null}

      {legacyId && legacyId !== ulpin ? (
        <div className="mt-1 font-mono text-[10px] text-[rgb(var(--muted))]">
          Formerly: {legacyId}
        </div>
      ) : null}

      <p className="mt-2 border-t border-[rgb(var(--edge))]/50 pt-1.5 text-[9px] leading-snug text-muted">
        {DISCLAIMER}
      </p>
    </div>
  );
}
