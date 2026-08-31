// checkpoint-051 UI 重设计：单色线条图标组件（规范 §7 + 附录 A）
// 零依赖内联 SVG：viewBox 24、stroke currentColor、stroke-width 1.5、圆头。
// 实心类例外（stop/play/send）用 fill=currentColor。
// 颜色跟随所在处文字颜色（currentColor）。
import React from 'react';

export type IconName =
  | 'plus' | 'x' | 'check' | 'check-circle'
  | 'chevron-down' | 'chevron-up' | 'chevron-right' | 'chevron-left'
  | 'arrow-left' | 'arrow-right' | 'arrow-up-right'
  | 'sliders' | 'pencil' | 'trash' | 'send' | 'stop' | 'play' | 'rotate-cw' | 'copy'
  | 'folder' | 'file' | 'file-text' | 'image' | 'paperclip' | 'message-circle'
  | 'bot' | 'user' | 'mic' | 'clipboard' | 'download' | 'external-link'
  | 'alert-triangle' | 'alert-circle' | 'info' | 'clock' | 'shield' | 'crown'
  | 'wrench' | 'plug' | 'layers' | 'book' | 'database' | 'cpu' | 'globe'
  | 'terminal' | 'key' | 'sparkle' | 'settings';

const PATHS: Record<IconName, React.ReactNode> = {
  plus: <path d="M12 5v14M5 12h14" />,
  x: <path d="M6 6l12 12M18 6L6 18" />,
  check: <path d="M5 12.5l4.5 4.5L19 7" />,
  'check-circle': <><circle cx="12" cy="12" r="9" /><path d="M8.5 12.5l2.5 2.5 5-5.5" /></>,
  'chevron-down': <path d="M6 9l6 6 6-6" />,
  'chevron-up': <path d="M6 15l6-6 6 6" />,
  'chevron-right': <path d="M9 6l6 6-6 6" />,
  'chevron-left': <path d="M15 6l-6 6 6 6" />,
  'arrow-left': <path d="M19 12H5M11 6l-6 6 6 6" />,
  'arrow-right': <path d="M5 12h14M13 6l6 6-6 6" />,
  'arrow-up-right': <path d="M7 17L17 7M8 7h9v9" />,
  sliders: <><path d="M4 7h16M4 12h16M4 17h16" /><circle cx="9" cy="7" r="2" /><circle cx="15" cy="12" r="2" /><circle cx="7" cy="17" r="2" /></>,
  pencil: <path d="M4 20l1-4L16.5 4.5a2.12 2.12 0 0 1 3 3L8 19l-4 1z" />,
  trash: <path d="M4 7h16M9 7V5h6v2M6.5 7l1 13h9l1-13M10 11v6M14 11v6" />,
  send: <path fill="currentColor" stroke="none" d="M3.4 20.4l17.8-8.4L3.4 3.6l-.4 6.9L13 12 3 13.5l.4 6.9z" />,
  stop: <rect fill="currentColor" stroke="none" x="6" y="6" width="12" height="12" rx="2" />,
  play: <path fill="currentColor" stroke="none" d="M8 5.5v13l11-6.5z" />,
  'rotate-cw': <><path d="M21 4v6h-6" /><path d="M20 14a8 8 0 1 1-1.9-6.7L21 10" /></>,
  copy: <><rect x="9" y="9" width="11" height="11" rx="2" /><path d="M5 15V5a2 2 0 0 1 2-2h10" /></>,
  folder: <path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7z" />,
  file: <><path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z" /><path d="M14 3v5h5" /></>,
  'file-text': <><path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z" /><path d="M14 3v5h5M9 13h6M9 17h4" /></>,
  image: <><rect x="3" y="4" width="18" height="16" rx="2" /><circle cx="8.5" cy="9.5" r="1.5" /><path d="M21 15.5l-5-5L6 20" /></>,
  paperclip: <path d="M21.4 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48" />,
  'message-circle': <path d="M21 11.5a8.5 8.5 0 0 1-8.5 8.5 8.4 8.4 0 0 1-3.8-.9L3 21l1.9-5.7a8.4 8.4 0 0 1-.9-3.8A8.5 8.5 0 0 1 12.5 3a8.5 8.5 0 0 1 8.5 8.5z" />,
  bot: <><rect x="5" y="9" width="14" height="10" rx="3" /><path d="M12 9V6" /><circle cx="12" cy="5" r="1" /><circle cx="9.5" cy="13.5" r="1" fill="currentColor" stroke="none" /><circle cx="14.5" cy="13.5" r="1" fill="currentColor" stroke="none" /></>,
  user: <><circle cx="12" cy="8" r="4" /><path d="M4 21c0-4 3.6-6 8-6s8 2 8 6" /></>,
  mic: <><rect x="9" y="2" width="6" height="12" rx="3" /><path d="M5 10v1a7 7 0 0 0 14 0v-1M12 18v4M8 22h8" /></>,
  clipboard: <><path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2" /><rect x="8" y="2" width="8" height="4" rx="1" /></>,
  download: <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4M7 10l5 5 5-5M12 15V3" />,
  'external-link': <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6M15 3h6v6M10 14L21 3" />,
  'alert-triangle': <><path d="M10.3 3.9L1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0zM12 9v4" /><path d="M12 17h.01" /></>,
  'alert-circle': <><circle cx="12" cy="12" r="9" /><path d="M12 8v4M12 16h.01" /></>,
  info: <><circle cx="12" cy="12" r="9" /><path d="M12 11v5M12 8h.01" /></>,
  clock: <><circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 2" /></>,
  shield: <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z" />,
  crown: <path d="M3 7.5l4.5 3.5L12 4.5l4.5 6.5L21 7.5l-1.8 10H4.8L3 7.5z" />,
  wrench: <path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z" />,
  plug: <path d="M9 2v6M15 2v6M6 8h12v3a6 6 0 0 1-12 0V8zM12 17v5" />,
  layers: <><path d="M12 2l10 5-10 5L2 7l10-5z" /><path d="M2 12l10 5 10-5M2 17l10 5 10-5" /></>,
  book: <><path d="M2 4h6a4 4 0 0 1 4 4v13a3 3 0 0 0-3-3H2z" /><path d="M22 4h-6a4 4 0 0 0-4 4v13a3 3 0 0 1 3-3h7z" /></>,
  database: <><ellipse cx="12" cy="5" rx="9" ry="3" /><path d="M21 12c0 1.66-4 3-9 3s-9-1.34-9-3M3 5v14c0 1.66 4 3 9 3s9-1.34 9-3V5" /></>,
  cpu: <><rect x="5" y="5" width="14" height="14" rx="2" /><rect x="9.5" y="9.5" width="5" height="5" /><path d="M9 2v3M15 2v3M9 19v3M15 19v3M2 9h3M2 15h3M19 9h3M19 15h3" /></>,
  globe: <><circle cx="12" cy="12" r="9" /><path d="M3 12h18M12 3a15 15 0 0 1 4 9 15 15 0 0 1-4 9 15 15 0 0 1-4-9 15 15 0 0 1 4-9z" /></>,
  terminal: <path d="M4 17l6-5-6-5M12 19h8" />,
  key: <><circle cx="7.5" cy="16" r="3.5" /><path d="M10.5 13.5L20 4M17 4h3v3" /></>,
  sparkle: <path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8L12 3z" />,
  settings: <><path d="M4 7h16M4 12h16M4 17h16" /><circle cx="9" cy="7" r="2" /><circle cx="15" cy="12" r="2" /><circle cx="7" cy="17" r="2" /></>,
};

export function Icon({ name, size = 16, style, className, title }: {
  name: IconName; size?: number; style?: React.CSSProperties; className?: string; title?: string;
}) {
  const isBig = size >= 36;
  const sw = isBig ? 1.25 : 1.5;
  return (
    <svg
      viewBox="0 0 24 24" width={size} height={size}
      fill="none" stroke="currentColor" strokeWidth={sw}
      strokeLinecap="round" strokeLinejoin="round"
      style={{ flexShrink: 0, ...style }} className={className}
      aria-hidden={title ? undefined : true}
    >
      {title ? <title>{title}</title> : null}
      {PATHS[name]}
    </svg>
  );
}

// 加载 spinner（规范 §5）：CSS 圆环旋转
export function Spinner({ size = 14, style }: { size?: number; style?: React.CSSProperties }) {
  return (
    <span
      style={{
        width: size, height: size, display: 'inline-block', flexShrink: 0,
        border: '2px solid #E3E3E8', borderTopColor: '#38BDF8', borderRadius: '50%',
        animation: 'ui-spin .8s linear infinite',
        ...style,
      }}
    />
  );
}
