import 'dart:async';

/// mDNS bulunan servis (host IPv4 adresi ya da ad).
typedef MdnsHit = ({String host, int port});

/// Web gibi mDNS'in kullanılamadığı platformlar için boş kaynak.
bool get mdnsSupported => false;

Stream<MdnsHit> mdnsServices(Duration timeout) => const Stream.empty();
