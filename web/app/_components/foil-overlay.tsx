/**
 * The foil treatment (38): a rainbow wash over the art plus a highlight that
 * sweeps across, as a foil does when it catches the light. Purely
 * decorative, so it is hidden from screen readers -- a "Foil" text badge
 * carries the meaning instead, since colour and motion should not be the
 * only way to tell. The sweep stops for anyone who asked for reduced motion
 * (`motion-reduce:animate-none`).
 *
 * Meant to sit as the last child of a `position: relative` art container.
 */
export function FoilOverlay() {
  return (
    <span aria-hidden className="pointer-events-none absolute inset-0 overflow-hidden">
      {/* The rainbow mask. Overlay blending rather than color-dodge: dodge is
          base / (1 - blend), which clips to white wherever the art is
          bright, so the tint would survive only in the darkest corner.
          Overlay keeps the art's lights and darks and tints them instead.
          The gradient is oversized so its hues can drift across without
          showing an edge. */}
      <span className="absolute inset-0 animate-foil-shift bg-[linear-gradient(115deg,rgba(255,64,160,0.55),rgba(255,196,64,0.55),rgba(120,255,180,0.55),rgba(64,176,255,0.55),rgba(190,110,255,0.55),rgba(255,64,160,0.55))] bg-[length:300%_300%] mix-blend-overlay motion-reduce:animate-none" />

      {/* The travelling band, rainbow rather than white so the movement
          carries colour too. */}
      <span className="absolute inset-y-0 left-0 w-1/2 animate-foil-sweep bg-[linear-gradient(100deg,transparent_0%,rgba(255,80,80,0.65)_18%,rgba(255,225,90,0.65)_34%,rgba(90,255,190,0.65)_50%,rgba(90,190,255,0.65)_66%,rgba(210,90,255,0.65)_82%,transparent_100%)] mix-blend-overlay motion-reduce:animate-none" />
    </span>
  )
}
