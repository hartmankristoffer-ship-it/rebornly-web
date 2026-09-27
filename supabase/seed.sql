-- WEB-02: LOCAL development data only. Never run against a hosted project.
-- Two invitations for trying the forum on the local stack; the code emails
-- land in the local mail catcher (http://127.0.0.1:55424). After signing in
-- and joining as owner@example.test, make that account a moderator with:
--   update forum.members set role = 'moderator'
--    where user_id = (select id from auth.users where email = 'owner@example.test');
insert into forum.invitations (email) values
  ('owner@example.test'),
  ('member@example.test')
on conflict (email) do nothing;
