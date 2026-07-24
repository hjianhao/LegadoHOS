import localUnitTest from './LocalUnit.test';
import bookSourceManagementTest from './BookSourceManagement.test';

export default function testsuite() {
  localUnitTest();
  bookSourceManagementTest();
}
