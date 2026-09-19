import Plan

namespace Refinement

-- The generated relation applies the fixed propositions to arbitrary subjects.
theorem valid : Plan.Relation := by
  simp_all [Plan.Relation, and_assoc]

end Refinement
