# Ratify Music: reply to App Review "Guideline 2.1 – Information Needed"

Paste section A into the reply in App Store Connect (Resolution Center), and also into
App Review Information → Notes. Attach the screen recording described in section B.
Do section C first: those items decide whether the reply is accurate.

---

## A. Reply text (fill in the [brackets])

Hello App Review team,

Thank you for reviewing Ratify Music. Here is the information you asked for.

**1. Screen recording**
Attached: a recording made on an iPhone running iOS [26.x]. It starts with launching the
app and shows:
- registering a new account and signing in;
- playing a game (choosing a category, ranking a Top 5, seeing the results);
- connecting Apple Music and playing a song;
- reporting content and blocking a user;
- opening a purchase;
- deleting the account (Profile → Delete Account).

**2. Purpose and target audience**
Ratify Music is a social music ranking game for music fans and groups of friends. Players
choose a music category (for example "Albums That Defined the 90s"), debate their picks, and
each rank their Top 5 songs, albums or artists. The app combines everyone's rankings into an
official group consensus and reveals it with music previews. The player whose list is closest
to the consensus wins. It turns the everyday "who's the greatest?" debate into a structured
game, and builds a community-wide ranking for every category over time.

**3. How to access the main features**
- Sign in with the demo account in App Review Information (email and password).
- Solo play (free): Home → "Try RATIFY Free" → pick a category → rank your Top 5 →
  "See My Results".
- Play with friends: Home → "Ratify Premium" → create a game and share its 5-digit code.
  Other players join from Home → "Join Game" with that code.
- Apple Music: Profile → "Connect Apple Music" → Allow. Full songs need an active Apple Music
  subscription on the device; without one, each song can still be opened in Apple Music.
- The demo account has credits, so games can be played without purchasing.
- Account deletion: Profile → Delete Account.

**4. External services**
- Base44: hosting, database, user accounts and sign-in, backend functions, file storage,
  email, and AI-generated debate topics (Base44's built-in AI integration).
- Sign in with Apple, Google, Facebook and Microsoft.
- Apple Music (MediaPlayer framework) for playback, and the iTunes Search/Lookup API for
  catalog data.
- Stripe for payments, through Stripe Checkout in Safari. [See C1.]
- Twilio for SMS phone verification in Ballot Box voting.
- Resend for transactional email.
- Sentry for error and crash reporting.
- YouTube and Vimeo for sponsor videos shown before free solo games.

**5. Regional differences**
[If available in the US only:] The app is available on the United States storefront only and
works the same for all users. It is in English and prices are in US dollars. Song
availability depends on the user's Apple Music storefront; unavailable songs show a message
and can still be opened in Apple Music.

**6. Regulated industry / third-party material**
Music is played only through the user's own Apple Music account using Apple's frameworks;
the app does not host or stream copyrighted audio. [Complete after C2. If paid entries,
raffles, prizes or payouts remain in the app, describe them here and attach the official
rules and any licences.]

Thank you,
Ratify LLC

---

## B. Screen recording shot list (on a real iPhone, latest iOS)

Use iOS's own Screen Recording (Control Center), on a physical iPhone, not the simulator.
Keep it to about 3–5 minutes, with no cuts before the app opens.

1. Start on the Home Screen and tap **Ratify Music**.
2. Sign-in screen → **Create account** with a new throwaway email, finish sign-up, and land on Home.
3. **Try RATIFY Free** → pick a category → add 5 picks → **See My Results** → show the results.
4. **Profile → Connect Apple Music → Allow**, then play a song. Use an iPhone whose Apple ID
   has an Apple Music subscription.
5. **Report and block** (once added, see C3): report a piece of content and block a user,
   then show **Profile → Blocked Users**.
6. **Paid features:** tap **Buy Credits** or **Ratify Premium** and show Stripe Checkout
   opening in Safari. Don't pay; just show the screen.
7. **Profile → Delete Account** → confirm, so the throwaway account is deleted, and show
   that you're signed out.

## C. Decide or fix before replying (otherwise Apple will reject)

1. **Purchases (3.1.1).** Credits, Premium, Live Host and paid game entry are all digital and
   sold through Stripe. Apple only allows that on the **US storefront** (external purchase
   links). Set Pricing and Availability → **United States only**, or add In-App Purchase.
2. **Real-money features (5.3, gambling and contests).**
   - The app has paid Live Game entry ($1.29), a "Raffle" with random winners, host cash-out
     in USD, and wager, gift-card and payout records.
   - Apple treats paid entry plus prizes, or payouts, as gambling or contests. That needs
     licences, geo-restriction, official rules, and often a "free to enter" route.
   - Safest for approval: hide raffles, wagers, cash-out and paid entry in the iOS app (for
     example when the user agent contains "RatifyApp"), and describe the app as a free-to-play
     ranking game.
3. **Report and block (1.2, user-generated content).**
   - Members see other users' content: display names, custom picks, category suggestions,
     Ballot Box banners and host profiles. Apple requires a way to report content and to
     block users.
   - The site has the data (`ContentReport`, `UserBlock`, admin ModerationPanel, Profile →
     Blocked Users) but no **Report** or **Block** button. Add both before recording.
4. **Demo account.** It must have credits, and phone verification must not block it.
5. **Ads.** Free solo games show a sponsor video first. Apple doesn't object, but the age
   rating should reflect any ad content.
