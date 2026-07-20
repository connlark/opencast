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
  Radio,
  Rss,
  ShieldCheck,
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
      {/* eslint-disable-next-line @next/next/no-img-element -- static export serves pre-optimized assets */}
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
                Independent. Native. Made for listeners.
              </p>
              <h1>
                Podcasts,
                <span>minus the noise.</span>
              </h1>
              <p className="hero-deck">
                opencast brings your RSS feeds, playback, transcripts, and
                listening progress together in one focused iPhone and iPad app.
              </p>
              <div className="hero-actions">
                <AppStoreBadge />
                <a href="#screens" className="hero-secondary-action">
                  See it in action
                  <ArrowRight aria-hidden="true" />
                </a>
              </div>
              <ul className="hero-proof" aria-label="opencast highlights">
                <li>
                  <Check aria-hidden="true" /> No account
                </li>
                <li>
                  <Check aria-hidden="true" /> Private sync
                </li>
                <li>
                  <Check aria-hidden="true" /> RSS first
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
                  <AudioLines />
                </span>
                <span>
                  <strong>Ad break found</strong>
                  <small>Marked on your timeline</small>
                </span>
              </div>
              <div className="hero-float hero-float--bottom" aria-hidden="true">
                <Radio />
                RSS in. Clutter out.
              </div>
            </div>
          </div>
        </section>

        <div className="signal-strip" aria-label="Core app qualities">
          <div className="site-shell signal-strip__inner">
            <p>
              <Sparkles aria-hidden="true" /> Native SwiftUI
            </p>
            <p>
              <Cloud aria-hidden="true" /> Private iCloud sync
            </p>
            <p>
              <Headphones aria-hidden="true" /> Stream by default
            </p>
            <p>
              <Rss aria-hidden="true" /> Bring any RSS feed
            </p>
          </div>
        </div>

        <section id="features" className="feature-showcase">
          <div className="site-shell">
            <header className="section-heading section-heading--ink">
              <p className="section-eyebrow">Designed around the episode</p>
              <h2>The app gets out of your way.</h2>
              <p>
                Everything you need for the daily listening loop, with none of
                the engagement machinery you do not.
              </p>
            </header>

            <div className="feature-grid">
              <article className="feature-panel feature-panel--library">
                <div className="feature-panel__copy">
                  <span className="feature-icon feature-icon--orange">
                    <Rss aria-hidden="true" />
                  </span>
                  <p className="feature-label">Library + Inbox</p>
                  <h3>Any RSS feed. One calm inbox.</h3>
                  <p>
                    Add a feed by URL, keep every subscription together, and
                    scan fresh episodes without an algorithm rearranging them.
                  </p>
                </div>
                <div className="library-preview" aria-hidden="true">
                  <div className="library-preview__bar">
                    <span>Today</span>
                    <strong>12 new</strong>
                  </div>
                  <div className="library-row">
                    <span className="library-art library-art--one" />
                    <span>
                      <strong>Signal Path</strong>
                      <small>Tracing the bug that only appeared at night</small>
                    </span>
                    <Play />
                  </div>
                  <div className="library-row">
                    <span className="library-art library-art--two" />
                    <span>
                      <strong>Independent Frequency</strong>
                      <small>New episode · 42 min</small>
                    </span>
                    <Play />
                  </div>
                </div>
              </article>

              <article className="feature-panel feature-panel--playback">
                <div className="feature-panel__copy">
                  <span className="feature-icon feature-icon--violet">
                    <Headphones aria-hidden="true" />
                  </span>
                  <p className="feature-label">Streaming playback</p>
                  <h3>Press play. Pick up later.</h3>
                  <p>
                    Stream from the feed, seek with native controls, and resume
                    from listening progress that actually remembers.
                  </p>
                </div>
                <div className="playback-preview" aria-hidden="true">
                  <div className="playback-preview__art" />
                  <div className="playback-preview__meta">
                    <strong>Signal Path</strong>
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

              <article className="feature-panel feature-panel--transcript">
                <div className="feature-panel__copy">
                  <span className="feature-icon feature-icon--mint">
                    <AudioLines aria-hidden="true" />
                  </span>
                  <p className="feature-label">Flexible transcripts</p>
                  <h3>Read along—or find the part you missed.</h3>
                  <p>
                    Transcribe on your device, or explicitly choose optional
                    remote transcription for an episode.
                  </p>
                </div>
                <div className="transcript-preview" aria-hidden="true">
                  <span className="transcript-preview__time">24:18</span>
                  <p>
                    The useful thing about a quiet interface is that
                    <mark> the story stays in front.</mark>
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
                  <p className="feature-label">Privacy-aware by design</p>
                  <h3>Your listening history is yours.</h3>
                  <p>
                    Subscriptions and progress can sync privately through
                    iCloud. Caches and downloads stay local to your device.
                  </p>
                </div>
                <div className="privacy-tags" aria-hidden="true">
                  <span>Private iCloud</span>
                  <span>Local downloads</span>
                  <span>No opencast login</span>
                </div>
              </article>
            </div>
          </div>
        </section>

        <section id="screens" className="screens-section">
          <div className="site-shell screens-section__heading">
            <header className="section-heading">
              <p className="section-eyebrow">Inside opencast</p>
              <h2>Made to feel at home on your phone.</h2>
              <p>
                Familiar controls, clear information, and every listening tool
                close enough to reach.
              </p>
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
              <h2>No opencast account. No feed lock-in.</h2>
            </div>
            <div className="promise-section__body">
              <p>
                opencast is built around open RSS feeds and the system services
                already on your Apple devices—not another profile to maintain.
              </p>
              <ul>
                <li>
                  <ShieldCheck aria-hidden="true" />
                  Private sync when you choose it
                </li>
                <li>
                  <BookOpen aria-hidden="true" />
                  Stable feed and episode identities
                </li>
                <li>
                  <Cloud aria-hidden="true" />
                  Local caches and explicit downloads
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
              <h2>Something not sounding right?</h2>
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
              <h2>Know where your data goes.</h2>
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
