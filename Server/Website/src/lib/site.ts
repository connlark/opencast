export const appStoreURL = "https://apps.apple.com/app/opencast/id6766770733";
export const supportEmail = "support@opencast.mobile";
export const githubURL = "https://github.com/connlark/opencast";
export const githubIssueURL = `${githubURL}/issues/new`;
export const marketingURL = "https://opencast.mobile";
export const supportHost = "support.opencast.mobile";
export const privacyURL = `https://${supportHost}/privacy`;

export const screenshots = [
  {
    src: "/screenshots/app_store_01_now_playing_framed.png",
    alt: "opencast Now Playing screen with detected ad breaks marked on the timeline",
  },
  {
    src: "/screenshots/app_store_02_transcript_framed.png",
    alt: "opencast transcript screen with a sponsor read flagged in orange",
  },
  {
    src: "/screenshots/app_store_03_notification_framed.png",
    alt: "opencast notification announcing ad breaks found in two episodes",
  },
  {
    src: "/screenshots/app_store_04_library_framed.png",
    alt: "opencast Library screen on iPhone",
  },
  {
    src: "/screenshots/app_store_05_podcast_detail_framed.png",
    alt: "opencast podcast detail screen with episode list",
  },
  {
    src: "/screenshots/app_store_06_sound_lab_framed.png",
    alt: "opencast Sound Lab with Voice Boost and ad skipping controls",
  },
  {
    src: "/screenshots/app_store_07_inbox_framed.png",
    alt: "opencast Inbox screen with fresh episodes",
  },
  {
    src: "/screenshots/app_store_08_episode_detail_framed.png",
    alt: "opencast episode detail screen with show notes and transcript",
  },
] as const;
