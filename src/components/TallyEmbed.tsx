interface Props {
  url: string;
  title: string;
  minHeight?: number;
}

export function TallyEmbed({ url, title, minHeight = 540 }: Props) {
  return (
    <iframe
      src={url}
      title={title}
      loading="lazy"
      width="100%"
      height={minHeight}
      style={{ border: 0, width: "100%", minHeight }}
      allow="clipboard-write"
    />
  );
}
