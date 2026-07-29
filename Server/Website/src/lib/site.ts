import { screenshotAssets } from "@/lib/screenshots.generated";

export const testFlightURL = "https://testflight.apple.com/join/3WtxfvfF";
export const supportEmail = "support@opencast.mobile";
export const githubURL = "https://github.com/connlark/opencast";
export const githubIssueURL = `${githubURL}/issues/new`;
export const marketingURL = "https://opencast.mobile";
export const supportHost = "support.opencast.mobile";

function screenshot<ID extends keyof typeof screenshotAssets>(id: ID, alt: string) {
  return { id, ...screenshotAssets[id], alt };
}

export const screenshots = [
  screenshot(
    "app_store_01_now_playing_framed",
    "opencast Now Playing screen with detected ad breaks marked on the timeline"
  ),
  screenshot(
    "app_store_02_transcript_framed",
    "opencast transcript screen with a sponsor read flagged in orange"
  ),
  screenshot(
    "app_store_03_notification_framed",
    "opencast notification announcing ad breaks found in two episodes"
  ),
  screenshot(
    "app_store_04_library_framed",
    "opencast Library screen on iPhone"
  ),
  screenshot(
    "app_store_05_podcast_detail_framed",
    "opencast podcast detail screen with episode list"
  ),
  screenshot(
    "app_store_06_sound_lab_framed",
    "opencast Sound Lab with Voice Boost and ad skipping controls"
  ),
  screenshot(
    "app_store_07_inbox_framed",
    "opencast Inbox screen with fresh episodes"
  ),
  screenshot(
    "app_store_08_episode_detail_framed",
    "opencast episode detail screen with show notes and transcript"
  ),
] as const;
