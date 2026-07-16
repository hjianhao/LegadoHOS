/** 本地书文件名相关的统一规则。 */
export function localBookTitleFromPath(filePath: string): string {
  if (!filePath) return '';
  const slash = Math.max(filePath.lastIndexOf('/'), filePath.lastIndexOf('\\'));
  const fileName = slash >= 0 ? filePath.slice(slash + 1) : filePath;
  return fileName.replace(/\.[^.]+$/i, '').trim();
}
