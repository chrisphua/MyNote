package io.mynote.app

/** Compile-time product switches. */
object AppFeatures {
    /**
     * Whether anything is for sale.
     *
     * **Off until MyNote is stable and published.** While it is off, every
     * feature is free: themes are editable, backup is available, no paywall is
     * ever shown, and Play Billing is not contacted at all.
     *
     * The purchasing code is kept rather than deleted — it works, it is covered
     * by the `License` tests in `:core`, and the cross-platform hand-off is the
     * fiddly part to rebuild. Flipping this to `true` restores the paywall; see
     * `docs/MONETIZATION.md` for what else that needs.
     *
     * One product decision to make before flipping it: people who installed
     * while it was free will notice a paywall appearing over features they
     * already had. Grandfathering them is the usual answer, and it needs a
     * marker written at first launch — so decide before there are users, not
     * after.
     */
    const val PAID_FEATURES_ENABLED = false
}
