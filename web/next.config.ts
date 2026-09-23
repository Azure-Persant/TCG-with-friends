import type { NextConfig } from "next";

// Card images are served from Supabase Storage's public bucket (17, 22), not
// hot-linked from gatcg.com -- next/image refuses any remote src that isn't
// explicitly allow-listed here.
const supabaseHostname = process.env.NEXT_PUBLIC_SUPABASE_URL
  ? new URL(process.env.NEXT_PUBLIC_SUPABASE_URL).hostname
  : undefined;

const nextConfig: NextConfig = {
  images: {
    remotePatterns: supabaseHostname
      ? [
          {
            protocol: "https",
            hostname: supabaseHostname,
            pathname: "/storage/v1/object/public/card-images/**",
          },
        ]
      : [],
  },
};

export default nextConfig;
