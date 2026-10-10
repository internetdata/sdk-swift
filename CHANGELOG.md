# Changelog

What each release changed for you, newest first. Each line is a commit's summary, linked to its full description and diff. Releases before 2.3.1 are described by their release commits.

## 2.6.1 - 2026-10-10

### Fixes

- Re-pin the spec to 2026.10.09: rotating a key needs apikeys.reveal ([`f01ea01`](https://github.com/internetdata/sdk-swift/commit/f01ea01564c9278e976ce96955389dcfabeef27d))

## 2.6.0 - 2026-10-09

### Features

- Re-pin the spec to 2026.10.08, adding the Open databases' open flag ([`dd78476`](https://github.com/internetdata/sdk-swift/commit/dd78476d871bfa88f9e0fde55962aca11dbcd456))

## 2.5.3 - 2026-10-06

### Fixes

- Wait out a Retry-After past 2^31 - 1 ms on the backoff ([`7ec7c6c`](https://github.com/internetdata/sdk-swift/commit/7ec7c6c66b120a6ae24b85078c736695f128456d))

## 2.5.2 - 2026-10-04

### Fixes

- Re-pin the spec to 2026.10.03: metadata needs no license ([`d656bc8`](https://github.com/internetdata/sdk-swift/commit/d656bc802898679488375c8f6123071d6c4dbb27))

## 2.5.1 - 2026-10-02

### Fixes

- End the device poll's wait at the code's expiry, and never crash on its interval ([`da9bedc`](https://github.com/internetdata/sdk-swift/commit/da9bedc51118e72fc0b5982128ab51e358d83ece))
- Refuse an impossible poll timeout before the first wait ([`e3bb746`](https://github.com/internetdata/sdk-swift/commit/e3bb74629e98ddd91aa18cec2b5ed5d438abaf28))

## 2.5.0 - 2026-09-30

### Features

- Add the authorization code sign-in, with PKCE ([`1fd6193`](https://github.com/internetdata/sdk-swift/commit/1fd6193eb154d94e6444d8a4fb9daaf55e83520b))

## 2.4.0 - 2026-09-27

### Features

- Re-pin the spec to 2026.09.26, adding its evaluation-sample fields ([`83eb5ca`](https://github.com/internetdata/sdk-swift/commit/83eb5cac786eb19ce216a2203c74f643d2d678cf))

## 2.3.1 - 2026-09-22

### Fixes

- Stop explaining in the docs how a private database is hidden ([`4f53f03`](https://github.com/internetdata/sdk-swift/commit/4f53f034691ebf6b2c6fb590ec54b4620d93610e))
