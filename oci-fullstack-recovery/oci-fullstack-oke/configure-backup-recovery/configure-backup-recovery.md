# Lab 5: Configure and Execute Full Stack Backup and Recovery

## Introduction

In this lab, use the supplied configuration script to configure OCI Full Stack Backup Recovery (BR) for protected resources in the Ashburn region. BR protects two compute virtual machines and their shared volume group within one region.

The workflow follows this sequence: backup policy, member backups, catalog and BR point, then recovery execution. Full Stack BR provides regional backup and recovery. Full Stack DR provides the cross-region workflow used in Labs 2–4.

**Before you begin:** Complete Lab 3 Task 2 and start the Start Drill execution. Then begin Lab 5 while the DR execution runs.

Complete the Full Stack BR activities while the DR execution runs. Start Lab 4 only after Lab 3 completes successfully.

Estimated Time: 20 minutes

### Objectives

In this lab, you will:

- Run the BR configuration script.
- Review the Ashburn BR protection group and its protected members.
- Verify the backup policy.
- Review the catalog and BR point.
- Run a backup or recovery plan and verify its execution.

## Task 1: Run the BR Configuration Script

1. In the Ashburn Cloud Shell, change to the application directory created in Lab 1.

    Run:

    ```bash
    <copy>
    cd ~/oci-ai-resiliency-lab
    </copy>
    ```

2. Run the OCI Full Stack Backup Recovery configuration script supplied with the lab environment.

    > **Script command placeholder:** Add the final script filename and command when the BR configuration script is available.

    The script should configure the BR protection group. It should add the two compute instances and shared volume group, associate the backup policy, and create the backup and recovery plans.

3. Monitor the script output until it returns successfully. Record the protection group, backup policy, plan, and execution identifiers that it reports.

## Task 2: Review the BR Protection Group

1. In the Ashburn OCI Console, open the navigation menu and select **Migration & Recovery**, then **Backup Recovery**.

2. Select the compartment used for the workshop and open the BR protection group created by the script.

3. Open the **Members** tab. Confirm that the protection group contains:

    - Compute VM 1.
    - Compute VM 2.
    - The volume group attached to both compute instances.

    The protection group defines the single-region Ashburn protection boundary. The volume group protects the application storage used by the compute members.

4. Confirm that the member resources are available and that the volume group is associated with the expected compute instances. Record any member or association warning before continuing.

## Task 3: Verify the Backup Policy

1. Open the **Backup Policy** tab for the BR protection group.

2. Review the policy settings. Confirm that the policy defines the required backup frequency, retention period, and destination for the lab tenancy.

3. Confirm that the policy settings match the values approved for the lab tenancy. Leave the policy unchanged unless the lab instructor provides different values.

4. Confirm that the policy applies to both compute members and the volume group. The policy establishes the backup posture; it does not create a recovery point until a backup plan runs.

## Task 4: Run and Verify the BR Plan

1. Open the **Plans** tab for the BR protection group. Review the available backup and recovery plans.

2. Open the plan specified by the lab exercise or instructor. Confirm that its steps include the required backup configuration, member backups, BR point creation or selection, and recovery actions.

3. Run the plan. Confirm the plan settings, then start the execution.

4. Open the execution details and monitor each plan group. Review task status, logs, warnings, and failures as the execution progresses.

5. Wait for the execution to complete successfully. Record the BR point identifier or execution identifier.

## Task 5: Create and Review a BR Point

1. Open the **Catalog** or **BR Points** tab for the protection group.

2. Review the available member backups. Confirm that the catalog lists backups for both compute instances and the volume group.

3. Select the BR point created by the completed Task 4 execution. Confirm its creation time, protected members, and status.

    A BR point represents a consistent recovery point assembled from the protected member backups. Use a completed BR point for recovery operations.

4. Confirm that the protected members remain associated with the BR protection group.

## Conclusion

You have completed **Build and Test Resiliency for AI Workloads with OCI Full Stack Disaster Recovery**. You configured and tested cross-region recovery with Full Stack DR. You then used Full Stack BR to protect and recover the Ashburn compute instances and volume group.

Together, OCI Full Stack DR and OCI Full Stack BR help you protect, recover, and validate the infrastructure, data, and application services that support a resilient AI workload.

## Acknowledgements

* **Author** - Suraj Ramesh, Lead Principal Product Manager, Oracle Database High Availability (HA), Scalability and Maximum Availability Architecture (MAA)
* **Last Updated By/Date** - August 2026
