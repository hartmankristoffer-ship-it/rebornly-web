// WEB-02: where the beta forum's own Supabase project lives. Both values are
// public by design (the publishable key only reaches the checked forum_*
// functions). While either is empty the forum is off: the page says so and
// makes no request. See docs/forum/RUNBOOK.md for switching it on, which also
// puts FORUM_URL's origin in connect-src in index.html.
window.REBORNLY_FORUM_CONFIG = Object.freeze({
  FORUM_URL: 'https://bdbxhduvbkaegzhaupcg.supabase.co',
  FORUM_KEY: 'sb_publishable_-0XmkE9719_PxUN82frVRQ_NdkBvNt6',
});
