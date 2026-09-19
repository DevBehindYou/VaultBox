import "dart:convert";

import "package:xml/xml.dart";

/// The `DAV:` XML namespace every standard WebDAV element lives in.
const String davNamespace = "DAV:";

/// Escapes text for use inside XML content or an attribute value.
String xmlEscape(String text) {
  return text
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;");
}

/// A property named by a client: namespace + local name.
final class DavProp {
  const DavProp(this.namespace, this.name);

  const DavProp.dav(String name) : this(davNamespace, name);

  final String namespace;
  final String name;

  bool get isDav => namespace == davNamespace;

  @override
  bool operator ==(Object other) => other is DavProp && other.namespace == namespace && other.name == name;

  @override
  int get hashCode => Object.hash(namespace, name);

  @override
  String toString() => "{$namespace}$name";
}

enum PropfindMode { allprop, propname, prop }

final class PropfindRequest {
  const PropfindRequest(this.mode, [this.props = const <DavProp>[]]);

  final PropfindMode mode;

  /// Only for [PropfindMode.prop].
  final List<DavProp> props;
}

enum DavLockScope { exclusive, shared }

final class LockRequest {
  const LockRequest({required this.scope, required this.owner});

  final DavLockScope scope;

  /// Free text the client gave to say who holds the lock (may be empty).
  final String owner;
}

/// The namespace an element is in, worked out from `xmlns` declarations on it or
/// its ancestors (the parser's own resolution is not relied on).
String? namespaceOf(XmlElement element) {
  final String? prefix = element.name.prefix;
  final String attribute = prefix == null ? "xmlns" : "xmlns:$prefix";
  XmlNode? node = element;
  while (node is XmlElement) {
    final String? value = node.getAttribute(attribute);
    if (value != null) return value;
    node = node.parent;
  }
  return null;
}

bool _isDav(XmlElement element, String local) => element.name.local == local && namespaceOf(element) == davNamespace;

XmlDocument _parse(List<int> body) {
  // Doctype declarations (and the entities they can define) have no place in
  // WebDAV bodies; refuse them outright rather than reason about expansion.
  final String text = utf8.decode(body);
  if (text.contains("<!DOCTYPE") || text.contains("<!ENTITY")) {
    throw const FormatException("DTDs are not accepted");
  }
  try {
    return XmlDocument.parse(text);
  } on XmlException catch (error) {
    throw FormatException("not well-formed XML: ${error.message}");
  }
}

/// A `PROPFIND` body. An empty body means "all properties".
PropfindRequest parsePropfind(List<int> body) {
  if (body.isEmpty || utf8.decode(body).trim().isEmpty) return const PropfindRequest(PropfindMode.allprop);

  final XmlElement root = _parse(body).rootElement;
  if (!_isDav(root, "propfind")) throw const FormatException("not a propfind");

  for (final XmlElement child in root.childElements) {
    if (_isDav(child, "allprop")) return const PropfindRequest(PropfindMode.allprop);
    if (_isDav(child, "propname")) return const PropfindRequest(PropfindMode.propname);
    if (_isDav(child, "prop")) {
      return PropfindRequest(PropfindMode.prop, <DavProp>[
        for (final XmlElement prop in child.childElements) DavProp(namespaceOf(prop) ?? "", prop.name.local),
      ]);
    }
  }
  throw const FormatException("propfind without allprop, propname or prop");
}

/// A `LOCK` body (`lockinfo`): only exclusive/shared write locks exist.
LockRequest parseLockInfo(List<int> body) {
  final XmlElement root = _parse(body).rootElement;
  if (!_isDav(root, "lockinfo")) throw const FormatException("not a lockinfo");

  DavLockScope? scope;
  String owner = "";
  bool write = false;
  for (final XmlElement child in root.childElements) {
    if (_isDav(child, "lockscope")) {
      for (final XmlElement s in child.childElements) {
        if (_isDav(s, "exclusive")) scope = DavLockScope.exclusive;
        if (_isDav(s, "shared")) scope = DavLockScope.shared;
      }
    } else if (_isDav(child, "locktype")) {
      write = child.childElements.any((XmlElement t) => _isDav(t, "write"));
    } else if (_isDav(child, "owner")) {
      owner = child.innerText.trim();
    }
  }
  if (scope == null || !write) throw const FormatException("unsupported lock");
  return LockRequest(scope: scope, owner: owner.length > 256 ? owner.substring(0, 256) : owner);
}

/// The properties a `PROPPATCH` tries to set or remove.
List<DavProp> parsePropertyUpdate(List<int> body) {
  final XmlElement root = _parse(body).rootElement;
  if (!_isDav(root, "propertyupdate")) throw const FormatException("not a propertyupdate");

  final List<DavProp> props = <DavProp>[];
  for (final XmlElement action in root.childElements) {
    if (!_isDav(action, "set") && !_isDav(action, "remove")) continue;
    for (final XmlElement prop in action.childElements.where((XmlElement e) => _isDav(e, "prop"))) {
      for (final XmlElement p in prop.childElements) {
        props.add(DavProp(namespaceOf(p) ?? "", p.name.local));
      }
    }
  }
  return props;
}

/// Builds a `207 Multi-Status` document.
final class MultiStatus {
  final StringBuffer _out = StringBuffer('<?xml version="1.0" encoding="utf-8"?>\n<D:multistatus xmlns:D="DAV:">');

  /// One `<D:response>` for [href], made of (status -> rendered property XML) groups.
  void response(String href, List<PropStat> groups) {
    _out.write("<D:response><D:href>${xmlEscape(href)}</D:href>");
    for (final PropStat group in groups) {
      _out.write(
        "<D:propstat><D:prop>${group.xml.join()}</D:prop>"
        "<D:status>HTTP/1.1 ${group.status} ${statusText(group.status)}</D:status></D:propstat>",
      );
    }
    _out.write("</D:response>");
  }

  List<int> toBytes() => utf8.encode("$_out</D:multistatus>");

  static String statusText(int status) => switch (status) {
    200 => "OK",
    403 => "Forbidden",
    404 => "Not Found",
    424 => "Failed Dependency",
    _ => "Status",
  };
}

final class PropStat {
  const PropStat(this.status, this.xml);

  final int status;

  /// Each entry is a complete, already-escaped property element.
  final List<String> xml;
}

/// An empty element for a property we don't know, in its own namespace.
/// Returns `null` when [prop]'s name can't be safely written as XML.
String? emptyPropXml(DavProp prop) {
  if (!RegExp(r"^[A-Za-z_][A-Za-z0-9._-]*$").hasMatch(prop.name)) return null;
  if (prop.isDav) return "<D:${prop.name}/>";
  return '<X:${prop.name} xmlns:X="${xmlEscape(prop.namespace)}"/>';
}
