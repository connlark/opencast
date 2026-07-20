import type { Metadata } from "next";
import { marketingURL } from "@/lib/site";

const socialImage = {
  url: `${marketingURL}/opengraph-image.jpg`,
  width: 1200,
  height: 630,
  alt: "opencast native podcast client for iPhone and iPad",
};

type PageMetadata = {
  title: string;
  description: string;
  url: string;
};

export function createPageMetadata({
  title,
  description,
  url,
}: PageMetadata): Metadata {
  return {
    title,
    description,
    alternates: { canonical: url },
    openGraph: {
      title,
      description,
      url,
      siteName: "opencast",
      images: [socialImage],
      locale: "en_US",
      type: "website",
    },
    twitter: {
      card: "summary_large_image",
      title,
      description,
      images: [socialImage],
    },
    robots: {
      index: true,
      follow: true,
      googleBot: {
        index: true,
        follow: true,
        noimageindex: false,
        "max-video-preview": -1,
        "max-image-preview": "large",
        "max-snippet": -1,
      },
    },
  };
}
