# Security

## Reporting a problem

If you find a security problem in Rondelle (a file that makes it write outside the chosen folder, read what it
shouldn't, reach the network, crash or use huge amounts of memory or time), please report it privately:

- open a **private vulnerability report** on GitHub (repository → *Security* → *Report a vulnerability*), or
- use the contact form in the app (Settings → Help and contact → Report a problem) and ask to be contacted, leaving your email.

Please describe the macOS and Rondelle versions, the steps, and, if you can, a small file that shows the problem.
Don't send files with personal data. You'll get an answer as soon as possible; fixes go into the next release and its
notes, with credit if you want it.

## What is in scope

- The app and its two network helpers, `UpdateCheck` and `FeedbackSend` (see *Privacy and security* in the README).
- Only the latest released version is supported.

Problems that need someone to already run code as your user, or to change the app on disk, are out of scope.
