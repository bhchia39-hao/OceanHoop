# OceanHoop (simple version)

One page: logo with water-ripple glow, what OceanHoop is, live counts of teams and courts, a list to browse them, two forms (add a team, add a court), future plans, and contact (Instagram @OCEAN_HOOP).
Courts use an address plus an optional Google Maps link. "Open in Google Maps" opens the place in Google Maps. There is no map of our own.

## Status
Written but NOT yet connected to a database or tested end to end. Until you finish setup, the site says "Setup not finished", shows "–" for counts, and the forms are switched off. Nothing is faked and no sample data exists.

## Setup
1. Create a free project at supabase.com.
2. SQL Editor: paste all of `schema.sql`, click Run. (If you ran an older `schema.sql` before, first run: `drop table if exists basketball_courts cascade;`)
3. Authentication > Providers > Email: turn OFF "Allow new users to sign up".
4. Authentication > Users > Add user: make your admin login.
5. SQL Editor: `insert into administrators (user_id, email) select id, email from auth.users where email = 'you@example.com';`
6. Project Settings > API: copy the Project URL and the anon/publishable key into `config.js`. Also put your email in `CONTACT_EMAIL` if you want it shown. Never use the service_role key.
7. Upload `index.html`, `config.js`, `logo.webp` to a GitHub repository, turn on Settings > Pages, open the address it gives you.

## Using it
- Visitors send teams and courts. Nothing appears until you approve it.
- Admin: add `#admin` to the web address, sign in, open Pending, press "Approve and publish". Counts update automatically.
- Contact emails and contact names stay private. There is no phone field.

## Not included on purpose
Own map, district boundaries, player stats, rankings, AI. These can be added later. Your boundary files from the zip are still safe on your computer.
