// Tiny icon set — single-stroke 16px line icons. Avoids heavy icon libs.
import * as React from "react";

type P = React.SVGProps<SVGSVGElement> & { size?: number };
const I = ({ size = 16, children, ...p }: P & { children: React.ReactNode }) => (
  <svg
    width={size} height={size} viewBox="0 0 24 24"
    fill="none" stroke="currentColor" strokeWidth={1.75}
    strokeLinecap="round" strokeLinejoin="round" {...p}
  >{children}</svg>
);

export const IcDatabase = (p: P) => (
  <I {...p}><ellipse cx="12" cy="5" rx="8" ry="3"/><path d="M4 5v6c0 1.7 3.6 3 8 3s8-1.3 8-3V5"/><path d="M4 11v6c0 1.7 3.6 3 8 3s8-1.3 8-3v-6"/></I>
);
export const IcPlay = (p: P) => (
  <I {...p}><path d="M6 4l14 8-14 8V4z"/></I>
);
export const IcSparkles = (p: P) => (
  <I {...p}><path d="M12 3v4M12 17v4M3 12h4M17 12h4M5.6 5.6l2.8 2.8M15.6 15.6l2.8 2.8M5.6 18.4l2.8-2.8M15.6 8.4l2.8-2.8"/></I>
);
export const IcZap = (p: P) => (
  <I {...p}><path d="M13 2L4 14h7l-1 8 9-12h-7l1-8z"/></I>
);
export const IcGauge = (p: P) => (
  <I {...p}><path d="M12 14l4-4"/><path d="M3.5 14a8.5 8.5 0 1117 0"/><path d="M3.5 14h17"/></I>
);
export const IcList = (p: P) => (
  <I {...p}><path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/></I>
);
export const IcPlus = (p: P) => <I {...p}><path d="M12 5v14M5 12h14"/></I>;
export const IcSearch = (p: P) => <I {...p}><circle cx="11" cy="11" r="7"/><path d="M21 21l-4.3-4.3"/></I>;
export const IcSettings = (p: P) => (
  <I {...p}><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 00.3 1.8l.1.1a2 2 0 11-2.8 2.8l-.1-.1a1.7 1.7 0 00-1.8-.3 1.7 1.7 0 00-1 1.5V21a2 2 0 11-4 0v-.1a1.7 1.7 0 00-1.1-1.5 1.7 1.7 0 00-1.8.3l-.1.1a2 2 0 11-2.8-2.8l.1-.1a1.7 1.7 0 00.3-1.8 1.7 1.7 0 00-1.5-1H3a2 2 0 110-4h.1a1.7 1.7 0 001.5-1.1 1.7 1.7 0 00-.3-1.8l-.1-.1a2 2 0 112.8-2.8l.1.1a1.7 1.7 0 001.8.3H9a1.7 1.7 0 001-1.5V3a2 2 0 114 0v.1a1.7 1.7 0 001 1.5 1.7 1.7 0 001.8-.3l.1-.1a2 2 0 112.8 2.8l-.1.1a1.7 1.7 0 00-.3 1.8V9a1.7 1.7 0 001.5 1H21a2 2 0 110 4h-.1a1.7 1.7 0 00-1.5 1z"/></I>
);
export const IcCopy = (p: P) => <I {...p}><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 01-2-2V4a2 2 0 012-2h9a2 2 0 012 2v1"/></I>;
export const IcCheck = (p: P) => <I {...p}><path d="M5 12l5 5L20 7"/></I>;
export const IcX = (p: P) => <I {...p}><path d="M18 6L6 18M6 6l12 12"/></I>;
export const IcChevronRight = (p: P) => <I {...p}><path d="M9 6l6 6-6 6"/></I>;
export const IcChevronDown = (p: P) => <I {...p}><path d="M6 9l6 6 6-6"/></I>;
export const IcAlert = (p: P) => <I {...p}><path d="M12 9v4M12 17h.01"/><path d="M10.3 3.86L1.82 18a2 2 0 001.71 3h16.94a2 2 0 001.71-3L13.7 3.86a2 2 0 00-3.4 0z"/></I>;
export const IcInfo = (p: P) => <I {...p}><circle cx="12" cy="12" r="9"/><path d="M12 16v-4M12 8h.01"/></I>;
export const IcSun = (p: P) => <I {...p}><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M4.93 19.07l1.41-1.41M17.66 6.34l1.41-1.41"/></I>;
export const IcMoon = (p: P) => <I {...p}><path d="M21 12.79A9 9 0 1111.21 3 7 7 0 0021 12.79z"/></I>;
export const IcClock = (p: P) => <I {...p}><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></I>;
export const IcTrendingDown = (p: P) => <I {...p}><path d="M22 17l-9.5-9.5-5 5L1 6"/><path d="M16 17h6v-6"/></I>;
export const IcTrendingUp = (p: P) => <I {...p}><path d="M22 7l-9.5 9.5-5-5L1 18"/><path d="M16 7h6v6"/></I>;
export const IcMessage = (p: P) => <I {...p}><path d="M21 15a2 2 0 01-2 2H7l-4 4V5a2 2 0 012-2h14a2 2 0 012 2z"/></I>;
export const IcLayers = (p: P) => <I {...p}><path d="M12 2L2 7l10 5 10-5-10-5z"/><path d="M2 17l10 5 10-5M2 12l10 5 10-5"/></I>;
export const IcKey = (p: P) => <I {...p}><circle cx="8" cy="15" r="4"/><path d="M10.85 12.15L19 4M18 5l2 2M15 8l2 2"/></I>;
export const IcSend = (p: P) => <I {...p}><path d="M22 2L11 13"/><path d="M22 2l-7 20-4-9-9-4 20-7z"/></I>;
export const IcTrash = (p: P) => <I {...p}><path d="M3 6h18M8 6V4a2 2 0 012-2h4a2 2 0 012 2v2M19 6l-1 14a2 2 0 01-2 2H8a2 2 0 01-2-2L5 6"/></I>;
