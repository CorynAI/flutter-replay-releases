## 0.2.0

* A response chunk that the app changes in place no longer changes the recorded body preview.
* Response previews decode every Latin-1 charset name that `package:http` accepts (`latin1`, `ISO_8859-1`, `cp819`),
  not only `iso-8859-1`.
* Request and response headers are recorded as they were sent and received: headers the app changes afterwards (for
  example before reading a previewed body) no longer change the report.

## 0.1.0

* First release: `CorynHttpClient` records `package:http` requests as Coryn API request events.
