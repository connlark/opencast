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
    "app_store_01_skip_framed",
    "opencast Now Playing with a Skipped promo pill and ad breaks marked on the timeline"
  ),
  screenshot(
    "app_store_02_transcript_framed",
    "opencast transcript with a sponsor read flagged in orange and the current line highlighted"
  ),
  screenshot(
    "app_store_03_sound_lab_framed",
    "opencast Sound Lab with Voice Boost, Skip Promos & Ads, and Show Transcript"
  ),
  screenshot(
    "app_store_04_search_framed",
    "opencast library search matching episode titles and a transcript passage"
  ),
  screenshot(
    "app_store_05_chapters_framed",
    "opencast episode page with generated chapters and a generated summary"
  ),
  screenshot(
    "app_store_06_pipeline_framed",
    "opencast episode page showing the download, transcribe, and detect ads progress card"
  ),
  screenshot(
    "app_store_07_notification_framed",
    "opencast new-episode notification with artwork and episode length"
  ),
  screenshot(
    "app_store_08_library_framed",
    "opencast Library with the docked mini player and tab bar"
  ),
  screenshot(
    "app_store_09_welcome_framed",
    "opencast welcome screen: no third-party analytics, view source on GitHub, tiny install"
  ),
  screenshot(
    "app_store_10_up_next_framed",
    "opencast Up Next queue over Now Playing"
  ),
] as const;
