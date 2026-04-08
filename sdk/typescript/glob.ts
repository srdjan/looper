export const globMatch = (path: string, pattern: string): boolean => {
  let source = pattern.replace(/[.+^${}()|[\]\\]/g, "\\$&");
  source = source.replace(/\/\*\*\//g, "\x01");
  source = source.replace(/^\*\*\//, "\x02");
  source = source.replace(/\/\*\*$/, "\x03");
  source = source.replace(/\*\*/g, "\x04");
  source = source.replace(/\*/g, "[^/]*");
  source = source.replace(/\?/g, "[^/]");
  source = source.replace(/\x01/g, "/(.+/)?");
  source = source.replace(/\x02/g, "(.+/)?");
  source = source.replace(/\x03/g, "(/.+)?");
  source = source.replace(/\x04/g, ".*");
  return new RegExp(`^${source}$`).test(path);
};

export const matchesAny = (
  path: string,
  patterns: readonly string[],
): boolean => patterns.some((pattern) => globMatch(path, pattern));
