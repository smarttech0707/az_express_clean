import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/services/partner_approval_service.dart';
void main(){
 test('reapproval reuses permanent ID regardless of proposed ID',(){expect(selectApprovalId({'status':'approved','pharmacieId':'old'},'pharmacieId','new'),'old');});
 test('legacy restaurant owner binding is preserved',(){expect(selectApprovalId({'status':'approved'},'restaurantId','new',ownerId:'old'),'old');});
 test('ambiguous approved legacy application cannot create a duplicate',(){expect(()=>selectApprovalId({'status':'approved'},'pharmacieId','new'),throwsStateError);});
 test('contradictory restaurant links are refused',(){expect(()=>selectApprovalId({'restaurantId':'a'},'restaurantId','new',ownerId:'b'),throwsStateError);});
 test('bakery stable UID and new request identity remain deterministic',(){expect(selectApprovalId({},'boulangerieId','new',stableId:'u'),'u');expect(selectApprovalId({},'pharmacieId','new'),'new');});
}
