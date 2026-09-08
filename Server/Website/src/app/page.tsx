import {
  ArrowRight,
  AudioLines,
  BookOpen,
  Check,
  Cloud,
  Headphones,
  LockKeyhole,
  Mail,
  Play,
  Rss,
  ShieldCheck,
  SkipForward,
  Sparkles,
} from "lucide-react";
import { AppStoreBadge } from "@/components/AppStoreBadge";
import { ScreenshotStrip } from "@/components/ScreenshotStrip";
import { SiteFooter } from "@/components/SiteFooter";
import { githubURL, screenshots, supportEmail } from "@/lib/site";

type Screenshot = (typeof screenshots)[number];

function AppScreenshot({ shot, eager = false }: { shot: Screenshot; eager?: boolean }) {
  return (
    <picture>
      <source type="image/avif" srcSet={shot.avifSrcSet} sizes="(min-width: 760px) 290px, 64vw" />
      <source type="image/webp" srcSet={shot.webpSrcSet} sizes="(min-width: 760px) 290px, 64vw" />
      <img
        src={shot.src}
        alt={shot.alt}
        width={shot.width}
        height={shot.height}
        loading={eager ? "eager" : "lazy"}
        fetchPriority={eager ? "high" : "auto"}
        decoding="async"
      />
    </picture>
  );
}

export default function HomePage() {
  return (
    <>
      <main className="marketing-page">
        <section id="home" className="home-hero">
          <div className="home-hero__glow" aria-hidden="true" />
          <div className="site-shell home-hero__grid">
            <div className="home-hero__copy">
              <p className="hero-kicker">
                <span aria-hidden="true" />
                ad-free. open source. no account.
              </p>
              <h1>
                podcasts,
                <span>minus the ads.</span>
              </h1>
              <p className="hero-deck">
                opencast finds the ad breaks in your podcasts and skips them,
                free. Your phone does the transcribing. No account, no
                tracking, and the source is open.
              </p>
              <div className="hero-actions">
                <AppStoreBadge />
                <a href="#screens" className="hero-secondary-action">
                  See it skip
                  <ArrowRight aria-hidden="true" />
                </a>
              </div>
              <ul className="hero-proof" aria-label="opencast highlights">
                <li>
                  <Check aria-hidden="true" /> Ad-free
                </li>
                <li>
                  <Check aria-hidden="true" /> No account
                </li>
                <li>
                  <Check aria-hidden="true" /> Open source
                </li>
              </ul>
            </div>

            <div className="hero-visual" aria-label="opencast app preview">
              <div className="hero-visual__halo" aria-hidden="true" />
              <div className="hero-shot hero-shot--back">
                <AppScreenshot shot={screenshots[1]} />
              </div>
              <div className="hero-shot hero-shot--front">
                <AppScreenshot shot={screenshots[0]} eager />
              </div>
              <div className="hero-float hero-float--top" aria-hidden="true">
                <span className="hero-float__icon">
                  <SkipForward />
                </span>
                <span>
                  <strong>Skipped promo</strong>
                  <small>Tap to undo</small>
                </span>
              </div>
              <div className="hero-float hero-float--bottom" aria-hidden="true">
                <LockKeyhole />
                No account. No tracking.
              </div>
            </div>
          </div>
        </section>

        <div className="signal-strip" aria-label="Core app qualities">
          <div className="site-shell signal-strip__inner">
            <p>
              <SkipForward aria-hidden="true" /> Ad skipping, free
            </p>
            <p>
              <Cloud aria-hidden="true" /> Private iCloud sync
            </p>
            <p>
              <Rss aria-hidden="true" /> Any RSS feed
            </p>
            <p>
              <Sparkles aria-hidden="true" /> MIT open source
            </p>
          </div>
        </div>

        <section id="features" className="feature-showcase">
          <div className="site-shell">
            <header className="section-heading section-heading--ink">
              <p className="section-eyebrow">Three things it does</p>
              <h2>skips the ads. keeps your data. reads the episode.</h2>
              <p>
                Ad breaks found in the transcript, a library that stays yours,
                and transcripts, search, and chapters when you want them.
              </p>
            </header>

            <div className="feature-grid">
              <article className="feature-panel feature-panel--skip">
                <div className="feature-panel__copy">
                  <span className="feature-icon feature-icon--library">
                    <SkipForward aria-hidden="true" />
                  </span>
                  <p className="feature-label">Ad-free, free</p>
                  <h3>the ads, skipped for you.</h3>
                  <p>
                    Download an episode and your phone transcribes it. opencast
                    finds the promo reads and skips the confident ones.
                    Borderline reads stay marked. One tap undoes a skip.
                  </p>
                </div>
                <div className="skip-preview" aria-hidden="true">
                  <div className="skip-preview__row">
                    <span className="library-art library-art--one" />
                    <span>
                      <strong>What the New Telescope Saw First</strong>
                      <small>Orbit Report · 49 min</small>
                    </span>
                  </div>
                  <div className="skip-preview__track">
                    <span className="skip-preview__fill" />
                    <i className="skip-preview__zone" style={{ left: "9%", width: "10%" }} />
                    <i className="skip-preview__zone skip-preview__zone--dim" style={{ left: "44%", width: "9%" }} />
                    <i className="skip-preview__zone" style={{ left: "68%", width: "9%" }} />
                    <i className="skip-preview__zone" style={{ left: "91%", width: "8%" }} />
                  </div>
                  <div className="skip-preview__pill">
                    <SkipForward />
                    Skipped promo
                    <small>Tap to undo</small>
                  </div>
                </div>
              </article>

              <article className="feature-panel feature-panel--transcript">
                <div className="feature-panel__copy">
                  <span className="feature-icon feature-icon--transcript">
                    <AudioLines aria-hidden="true" />
                  </span>
                  <p className="feature-label">Reads the episode</p>
                  <h3>every word, searchable.</h3>
                  <p>
                    Transcripts on your device, with tap-to-seek and
                    follow-along highlighting. Search everything ever said in
                    your library. Chapters and summaries on request (optional,
                    paid).
                  </p>
                </div>
                <div className="transcript-preview" aria-hidden="true">
                  <span className="transcript-preview__time">1:03</span>
                  <p>
                    First <mark>light</mark> is what astronomers call the first
                    real image a new telescope takes.
                  </p>
                  <span className="transcript-preview__line" />
                  <span className="transcript-preview__line transcript-preview__line--short" />
                </div>
              </article>

              <article className="feature-panel feature-panel--privacy">
                <div className="privacy-mark" aria-hidden="true">
                  <LockKeyhole />
                  <span />
                </div>
                <div className="feature-panel__copy">
                  <p className="feature-label">Yours, not ours</p>
                  <h3>no account. no tracking.</h3>
                  <p>
                    No opencast login, no analytics SDK. Subscriptions and
                    progress sync through your private iCloud. MIT-licensed
                    code, and the whole app is about 10 MB.
                  </p>
                </div>
                <div className="privacy-tags" aria-hidden="true">
                  <span>Private iCloud</span>
                  <span>No login</span>
                  <span>MIT license</span>
                </div>
              </article>

              <article className="feature-panel feature-panel--playback">
                <div className="feature-panel__copy">
                  <span className="feature-icon feature-icon--playback">
                    <Headphones aria-hidden="true" />
                  </span>
                  <p className="feature-label">A complete player</p>
                  <h3>voice boost. carplay. up next.</h3>
                  <p>
                    Voice Boost levels quiet hosts like a broadcast chain. Up
                    Next, speed, sleep timer, AirPlay, per-show intro and outro
                    skip, plus Siri and CarPlay.
                  </p>
                </div>
                <div className="playback-preview" aria-hidden="true">
                  <div className="playback-preview__art" />
                  <div className="playback-preview__meta">
                    <strong>Orbit Report</strong>
                    <span>32 minutes remaining</span>
                  </div>
                  <div className="playback-preview__track">
                    <span />
                  </div>
                  <span className="playback-preview__button">
                    <Play />
                  </span>
                </div>
              </article>
            </div>
          </div>
        </section>

        <section id="screens" className="screens-section">
          <div className="site-shell screens-section__heading">
            <header className="section-heading">
              <p className="section-eyebrow">Inside opencast</p>
              <h2>what it looks like.</h2>
              <p>The real app, screen by screen. Swipe through the whole set.</p>
            </header>
            <p className="screens-section__hint">
              Swipe to explore <ArrowRight aria-hidden="true" />
            </p>
          </div>
          <ScreenshotStrip />
        </section>

        <section className="promise-section">
          <div className="site-shell promise-section__grid">
            <div>
              <p className="section-eyebrow">Yours by default</p>
              <h2>not a growth funnel.</h2>
            </div>
            <div className="promise-section__body">
              <p>
                opencast has no account to create, no analytics to phone home,
                and no ads of its own. It is built on open RSS feeds and the
                system services already on your iPhone, and the source is on
                GitHub under the MIT license.
              </p>
              <ul>
                <li>
                  <ShieldCheck aria-hidden="true" />
                  No opencast account, ever
                </li>
                <li>
                  <Cloud aria-hidden="true" />
                  Private iCloud sync when you choose it
                </li>
                <li>
                  <BookOpen aria-hidden="true" />
                  MIT-licensed, built in the open
                </li>
              </ul>
            </div>
          </div>
        </section>

        <section id="support-privacy" className="closing-section">
          <div className="site-shell closing-section__grid">
            <article className="closing-card closing-card--support">
              <span className="closing-card__icon">
                <Mail aria-hidden="true" />
              </span>
              <p className="feature-label">Human support</p>
              <h2>something not sounding right?</h2>
              <p>
                Tell us what happened and include the feed URL when a podcast is
                involved. We will help you sort it out.
              </p>
              <a href={`mailto:${supportEmail}`}>
                Email support <ArrowRight aria-hidden="true" />
              </a>
            </article>

            <article className="closing-card closing-card--privacy">
              <span className="closing-card__icon">
                <ShieldCheck aria-hidden="true" />
              </span>
              <p className="feature-label">Plain-language privacy</p>
              <h2>know where your data goes.</h2>
              <p>
                Read the full policy for sync, notifications, downloads, and
                optional remote transcription.
              </p>
              <a href="/privacy">
                Read the privacy policy <ArrowRight aria-hidden="true" />
              </a>
            </article>
          </div>
          <div className="site-shell closing-section__source">
            <p>Built in the open.</p>
            <a href={githubURL}>
              View opencast on GitHub <ArrowRight aria-hidden="true" />
            </a>
          </div>
        </section>
      </main>
      <SiteFooter variant="marketing" />
    </>
  );
}
